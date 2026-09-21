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
      # `results` is a matrix; for single/multi-choice questions the SaaS
      # returns a single row whose columns line up 1:1 with the choices in the
      # order they were sent to `POST /processes` — which is
      # `question.response_options.order(:id)`, so the mapping is by index.
      # Counts come back as strings.
      #
      # ## Polling for the final tally
      #
      # For a `secretUntilTheEnd` question, `results` is absent (or non-final)
      # until the chain has finished decrypting the tally — an operation that
      # only starts when every question of the process has reached `ENDED`,
      # and that takes on the order of minutes. There is no SaaS webhook or
      # event to signal "results ready", so the job reschedules itself on a
      # bounded cadence until every question reports `finalResults: true` (or
      # until the retry budget runs out — a safety cap so we never loop
      # forever on a stuck tally).
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

        # Bounded polling for `secretUntilTheEnd` tallies. 30 × 120s = 60 min,
        # comfortably longer than the chain's decryption window in practice.
        # Past this we give up polling and keep whatever partial tally the
        # last run wrote — the admin can re-click Publish results to try again.
        MAX_POLL_ATTEMPTS = 30
        POLL_CADENCE_S = 120

        def perform(election_id, attempt: 1)
          @election = Decidim::Elections::Election.find_by(id: election_id)
          return if election.blank?

          @process = election.vocdoni_process
          return if process.blank? || process.vocdoni_process_id.blank?
          # A process that never reached the chain has no tally to pull —
          # `GET /processes/{id}/results` would answer with an empty
          # `questions` array or a 404.
          return unless process.published?

          remote = client.elections.results(process.vocdoni_process_id, authenticated: false).to_h
          remote_questions = Array(remote["questions"]).grep(Hash)

          apply_results!(remote_questions) if remote_questions.any?
          log_summary(remote_questions, attempt:)
          reschedule_if_not_final!(remote_questions, attempt:)
        rescue Decidim::Elections::Vocdoni::ApiError => e
          process&.record_failure!(redact(e.message), step: "sync_results", code: e.try(:code))
          raise if e.transient?
        end

        private

        attr_reader :process

        def apply_results!(remote_questions)
          local_questions = election.questions.order(:id).to_a

          remote_questions.each_with_index do |remote_question, index|
            local = local_questions[index]
            next if local.blank?

            row = extract_row(remote_question["results"])
            next if row.blank?

            options = local.response_options.order(:id).to_a
            row.each_with_index do |raw_count, choice_index|
              option = options[choice_index]
              next if option.blank?

              option.update_columns(votes_count: raw_count.to_i) # rubocop:disable Rails/SkipsModelValidations
            end
          end
        end

        # SaaS returns `results` as a matrix — for single-/multi-choice
        # questions there is exactly one row that holds one count per choice.
        # Anything shaped differently (a `secretUntilTheEnd` question whose
        # tally has not been decrypted yet, a future ranked/quadratic
        # variant) is left alone: we would not know how to project it onto a
        # per-option counter.
        def extract_row(results)
          return nil if results.blank?
          return nil unless results.is_a?(Array)
          return nil unless results.length == 1

          row = results.first
          row.is_a?(Array) ? row : nil
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

          self.class
              .set(wait: POLL_CADENCE_S.seconds)
              .perform_later(election.id, attempt: attempt + 1)
        end

        def log_summary(remote_questions, attempt:)
          total = remote_questions.sum { |q| q["voteCount"].to_i }
          not_final = remote_questions.count { |q| q["finalResults"] != true }
          suffix = not_final.positive? ? " — #{not_final} question(s) not yet final (attempt #{attempt}/#{MAX_POLL_ATTEMPTS})" : ""

          Rails.logger.info(
            "[vocdoni] synced results for election ##{election.id} " \
            "(process #{process.vocdoni_process_id}, #{remote_questions.size} question(s), #{total} vote(s))#{suffix}"
          )
        end
      end
    end
  end
end
