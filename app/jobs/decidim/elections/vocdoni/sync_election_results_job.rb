# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Enqueued from `subscribe_to_publish_results` when the admin clicks
      # "Publish results" on a Vocdoni-backed election, and from
      # `EndProcessOnChainJob` right after the on-chain ENDED transition
      # confirms so the tally lands in the sidecar without a human refresh.
      #
      # For a Vocdoni election the authoritative tally is on chain. Upstream's
      # `UpdateElectionStatus(:publish_results)` only writes
      # `election.published_results_at = Time.current` and never touches the
      # `Decidim::Elections::ResponseOption#votes_count` counter — so the
      # public results view keeps rendering `0 / 0 / 0` even after publish.
      # This job pulls `GET /processes/{id}/results` from the SaaS and mirrors
      # the tally into that counter, one row per response option.
      #
      # The SaaS response shape (see `spec/fixtures/vocdoni/process_results.json`):
      #
      #   { "questions" => [
      #       { "questionId" => "…", "voteCount" => 4, "finalResults" => true,
      #         "results" => [["2", "1", "1"]] },
      #       …
      #   ] }
      #
      # `results` is the Vochain tally matrix: one row per ballot field, one
      # column per value that field can take, each cell the number of ballots
      # that put that value in that field (as a string). Choices line up with
      # `question.response_options.order(:id)`, the order they were sent to
      # `POST /processes`, so the mapping is by index:
      #
      # * `single_option` (`singlechoice`) is one field holding the chosen
      #   choice's index: a single row with a bucket per choice.
      # * `multiple_option` (`multichoice`) is one 0/1 field per choice: a row
      #   per choice, `[not selected, selected]`, so a choice's count is
      #   column 1 of its row.
      #
      # A matrix of any other shape is not written: the question gets an
      # entry in `Process#question_failures`, shown on the admin dashboard,
      # until a run reads a matrix it can map.
      #
      # ## Modes
      #
      # `mode: :poll_until_final` (default) — for a `secretUntilTheEnd`
      # question, `results` is absent (or non-final) until the chain has
      # finished decrypting the tally — an operation that starts when that
      # question (its own Vochain election) reaches `ENDED`, and that takes on
      # the order of minutes. There is no SaaS webhook or event to signal
      # "results ready", so the job reschedules itself on a bounded cadence
      # until every question reports `finalResults: true` (or the retry
      # budget runs out — a safety cap so we never loop forever on a stuck
      # tally). This is the mode `subscribe_to_publish_results` and
      # `EndProcessOnChainJob` enqueue with.
      #
      # `mode: :one_shot` — a single apply-and-return with no self-reschedule
      # and no retry-budget check. Used by `SyncProcessJob` on the live-results
      # (`results_availability == "real_time"`) polling path: the outer job is
      # already looping on its own cadence, so results-sync just needs to keep
      # up with each tick.
      #
      # ## Per question
      #
      # `question_ids:` (Decidim ids) limits both the write and the finality
      # check to those questions — a `per_question` election publishes one
      # question's results while the others are still paused or voting.
      # Remote questions are matched to local ones by the sidecar's
      # `vocdoni_question_id`, falling back to position.
      #
      # ## Idempotency
      #
      # The write path uses `update_columns` on each `ResponseOption` so that
      # the (fake) counter is set without triggering `belongs_to :question,
      # counter_cache: true` — otherwise every re-run would inflate
      # `question.response_options_count` (which is a different counter, but
      # `update` on `ResponseOption` walks the belongs_to touch chain).
      class SyncElectionResultsJob < ApplicationJob
        queue_as :vocdoni

        retry_on Decidim::Elections::Vocdoni::ApiError, wait: :polynomially_longer, attempts: 3

        # Bounded polling for `secretUntilTheEnd` tallies. The chain usually
        # decrypts within ~20 s of ENDED, so the first waits are short and
        # back off to `POLL_CADENCE_S` for slow tallies. 35 attempts make a
        # 60 min window (see `poll_delay`). Past this we give up polling and
        # keep whatever partial tally the last run wrote — the admin can
        # re-click Publish results to try again.
        MAX_POLL_ATTEMPTS = 35
        POLL_BACKOFF_S = [5, 10, 15, 30, 60].freeze
        POLL_CADENCE_S = 120

        MODES = [:poll_until_final, :one_shot].freeze

        # `Process#question_failures` step of a matrix this job could not map.
        RESULTS_STEP = "sync_results"

        # Seconds to wait before the attempt after `attempt` (1-based).
        def self.poll_delay(attempt)
          POLL_BACKOFF_S.fetch(attempt - 1, POLL_CADENCE_S)
        end

        def perform(election_id, mode: :poll_until_final, attempt: 1, question_ids: nil)
          validate_mode!(mode)
          return unless bootstrap!(election_id)

          @question_ids = question_ids&.map(&:to_i)
          sync_and_maybe_reschedule!(mode:, attempt:)
        rescue Decidim::Elections::Vocdoni::ApiError => e
          process&.record_failure!(redact(e.message), step: "sync_results", code: e.try(:code), keep_state: true)
          raise if e.transient?
        end

        private

        attr_reader :process, :question_ids

        def validate_mode!(mode)
          return if MODES.include?(mode)

          raise ArgumentError, "Unknown mode #{mode.inspect}, expected one of #{MODES.inspect}"
        end

        # Loads the election and its sidecar into `@election` / `@process`;
        # returns false when the job should short-circuit (no election, no
        # sidecar, or a sidecar that never made it on chain — in any of those
        # cases there is nothing to pull from `GET /processes/{id}/results`).
        def bootstrap!(election_id)
          @election = Decidim::Elections::Election.find_by(id: election_id)
          return false if election.blank?

          @process = election.vocdoni_process
          return false if process.blank? || process.vocdoni_process_id.blank?
          return false unless process.published?

          true
        end

        def sync_and_maybe_reschedule!(mode:, attempt:)
          remote = client.elections.results(process.vocdoni_process_id, authenticated: false).to_h
          all_remote_questions = Array(remote["questions"]).grep(Hash)
          pairs = paired(all_remote_questions)
          remote_questions = pairs.map(&:first)

          apply_results!(pairs)
          sync_vote_counts!(pairs)
          log_summary(remote_questions, mode:, attempt:)
          reschedule_if_not_final!(remote_questions, attempt:) if mode == :poll_until_final
          record_vote_count!(all_remote_questions)
        end

        # {SyncResultsAfterVoteJob} compares this total across checks to tell
        # when a reported vote reached the tally.
        def record_vote_count!(remote_questions)
          return if remote_questions.empty? || !process.has_attribute?(:synced_vote_count)

          process.update_columns(synced_vote_count: remote_questions.sum { |q| q["voteCount"].to_i }) # rubocop:disable Rails/SkipsModelValidations
        end

        def apply_results!(pairs)
          pairs.each do |remote_question, local|
            results = remote_question["results"]
            # No tally yet: an encrypted question not decrypted, or no votes.
            next if results.blank?

            options = local.response_options.order(:id).to_a
            counts = option_counts(local, options.size, results)
            next record_unexpected_results!(local, results) if counts.nil?

            options.zip(counts).each do |option, count|
              option.update_columns(votes_count: count) # rubocop:disable Rails/SkipsModelValidations
            end
            clear_results_failure!(local)
          end
        end

        # One count per response option, or nil when the matrix does not have
        # the shape the question's type produces on chain.
        def option_counts(question, size, results)
          return nil if size.zero? || !results.is_a?(Array) || !results.all?(Array)

          cells = case question.question_type.to_s
                  when "single_option" then single_option_cells(results, size)
                  when "multiple_option" then multiple_option_cells(results, size)
                  end
          parse_counts(cells) if cells
        end

        def parse_counts(cells)
          counts = cells.map { |cell| Integer(cell.to_s, exception: false) }
          counts if counts.all? { |count| count.is_a?(Integer) && !count.negative? }
        end

        def single_option_cells(results, size)
          results.first if results.size == 1 && results.first.size == size
        end

        def multiple_option_cells(results, size)
          return nil unless results.size == size && results.all? { |row| row.size == 2 }

          results.map { |row| row[1] }
        end

        def record_unexpected_results!(question, results)
          message = "Unexpected results from Vocdoni for a #{question.question_type} question with " \
                    "#{question.response_options.size} options (#{matrix_shape(results)}); its counts were not written"
          Rails.logger.error "[vocdoni] question ##{question.id} of election ##{election.id}: #{message}"
          process.record_question_failure!(question.id, message, step: RESULTS_STEP)
        end

        def matrix_shape(results)
          return "a #{results.class.name}, not a matrix" unless results.is_a?(Array)

          "row sizes #{results.map { |row| row.is_a?(Array) ? row.size : row.class.name }.inspect}"
        end

        # Only a failure this job recorded: a chain status failure for the
        # same question stays until UpdateQuestionOnChainJob clears it.
        def clear_results_failure!(question)
          return unless process.question_failures.dig(question.id.to_s, "step") == RESULTS_STEP

          process.clear_question_failure!(question.id)
        end

        # Writes `voteCount` from each remote question into the local question
        # counter, then recomputes the election total from all its questions.
        def sync_vote_counts!(pairs)
          return if pairs.empty?

          pairs.each do |remote_question, local|
            local.update_columns(votes_count: remote_question["voteCount"].to_i) # rubocop:disable Rails/SkipsModelValidations
          end

          election.update_columns(votes_count: election.questions.sum(:votes_count)) # rubocop:disable Rails/SkipsModelValidations
        end

        # `[remote, local]` for every remote question with a local match,
        # keeping only those in `question_ids` when given.
        def paired(remote_questions)
          local_questions = election.questions.order(:id).to_a
          by_vocdoni_id = process.questions_metadata.to_h do |row|
            [row["vocdoni_question_id"].to_s, row["decidim_question_id"].to_i]
          end

          remote_questions.each_with_index.filter_map do |remote_question, index|
            local_id = by_vocdoni_id[(remote_question["questionId"] || remote_question["id"]).to_s]
            local = local_id ? local_questions.find { |question| question.id == local_id } : local_questions[index]
            next if local.blank?
            next if question_ids&.exclude?(local.id)

            [remote_question, local]
          end
        end

        # True when the SaaS says every question has been tallied to
        # completion. An empty `questions` array (SaaS has nothing to report
        # yet) is deliberately not "final" — we want to keep polling until
        # the chain publishes something.
        def all_final?(remote_questions)
          return false if remote_questions.empty?

          remote_questions.all? { |question| question["finalResults"] == true }
        end

        def reschedule_if_not_final!(remote_questions, attempt:)
          return if all_final?(remote_questions)
          return if attempt >= MAX_POLL_ATTEMPTS

          options = { attempt: attempt + 1 }
          options[:question_ids] = question_ids if question_ids
          self.class
              .set(wait: self.class.poll_delay(attempt).seconds)
              .perform_later(election.id, **options)
        end

        def log_summary(remote_questions, mode:, attempt:)
          total = remote_questions.sum { |q| q["voteCount"].to_i }
          not_final = remote_questions.count { |q| q["finalResults"] != true }
          suffix =
            if mode != :poll_until_final
              " (#{mode.to_s.dasherize})"
            elsif not_final.positive?
              " — #{not_final} question(s) not yet final (attempt #{attempt}/#{MAX_POLL_ATTEMPTS})"
            else
              ""
            end

          Rails.logger.info(
            "[vocdoni] synced results for election ##{election.id} " \
            "(process #{process.vocdoni_process_id}, #{remote_questions.size} question(s), #{total} vote(s))#{suffix}"
          )
        end
      end
    end
  end
end
