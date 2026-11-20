# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Polls the Vocdoni SaaS for the on-chain state of a published process
      # and mirrors it into the {Process} sidecar so the admin dashboard and
      # the voter booth do not each have to call the API.
      #
      # Enqueued from {PublishElectionJob} right after `POST /processes` and
      # again from itself while the process is still visible on chain, so a
      # deferred SaaS confirmation (the "publish did not confirm all questions
      # after 3 rounds" case) resolves without a human refreshing anything —
      # and, for a live-results election, the tally on `response_options.
      # votes_count` stays fresh throughout voting.
      #
      # ## Cadence
      #
      # Rescheduling is decided from the SaaS `status` returned by
      # `GET /processes/{id}`, not from the sidecar state (which collapses
      # every chain-side status onto `published`). Two speeds:
      #
      # * `READY` / `ONGOING` / `PAUSED` — active voting window. Poll every
      #   `LIVE_CADENCE_S` when the election is `real_time`, or every
      #   `IDLE_CADENCE_S` otherwise. For `real_time` each tick also fires a
      #   `SyncElectionResultsJob` in `:one_shot` mode (no self-reschedule —
      #   the outer loop is here) as a fallback to the vote-driven
      #   {SyncResultsAfterVoteJob}.
      # * `ENDED` / `RESULTS` / `CANCELED` / `PROCESS_UNKNOWN` — voting is
      #   over. Nothing to poll for; the post-end tally sync is chained from
      #   `EndProcessOnChainJob` on its own polling loop.
      class SyncProcessJob < ApplicationJob
        queue_as :vocdoni

        retry_on Decidim::Elections::Vocdoni::ApiError, wait: :polynomially_longer, attempts: 3

        # `publishing`: sidecar has an id but SaaS has not confirmed the
        # chain-side publish yet. Poll aggressively so the delay from an
        # admin's Publish click to the sidecar going `published` stays short.
        PUBLISHING_CADENCE_S = 30

        # Base cadence during the active voting window
        # (`READY` / `ONGOING` / `PAUSED`) for non-real-time elections. Just
        # keeps the sidecar's `saas_status` and turnout metadata fresh so the
        # admin dashboard has something recent to show. Public GET, no cost.
        IDLE_CADENCE_S = 300

        # Cadence during active voting when the election is
        # `results_availability: "real_time"`. A fallback only: the tally is
        # kept fresh by {SyncResultsAfterVoteJob}, which the booth triggers
        # after each cast. This tick catches votes cast outside our booth or
        # a lost notification. One anonymous GET on the public endpoint per
        # tick.
        LIVE_CADENCE_S = 60

        # SaaS statuses that mean the voting window is still open. Match on
        # upcase because the SaaS spells them upper. `GET /processes/{id}`
        # returns this per-question, not process-wide: a process is treated
        # as active while ANY question is still in one of these states.
        ACTIVE_STATUSES = %w(READY ONGOING PAUSED).freeze

        # Chain statuses a question never leaves.
        TERMINAL_STATUSES = %w(ENDED RESULTS CANCELED).freeze

        # Time the admin's own job gets to land a move before the reconciler steps in.
        RECONCILE_GRACE = 2.minutes

        # Longer than the slowest step of a question's own retry loop (120 s).
        FAILURE_RETRY_WINDOW = 5.minutes

        def perform(election_id)
          @election = Decidim::Elections::Election.find_by(id: election_id)
          return if election.blank?

          @process = election.vocdoni_process
          return if process.blank? || process.vocdoni_process_id.blank?

          Decidim::Elections::Vocdoni.validate_configuration!

          remote = client.elections.get(process.vocdoni_process_id).to_h
          persist!(remote)
          reconcile!(remote)
          sync_live_results!(remote)
          reschedule_if_needed!(remote)
        rescue Decidim::Elections::Vocdoni::ApiError => e
          # Transient errors are retried by ActiveJob; a permanent 4xx is
          # recorded on the sidecar so the admin dashboard can surface it.
          # A published election stays usable whatever this read says (#84).
          process&.record_failure!(redact(e.message), step: "sync", keep_state: process.published?) unless e.transient?
          raise
        end

        private

        attr_reader :process

        # Merges the on-chain state into the sidecar. Any of these fields may
        # be missing on a given call — the SaaS fills them in as the on-chain
        # confirmation lands. Under the row lock, so metadata other jobs wrote
        # since this run loaded the process (pending actions, failures) survives.
        def persist!(remote)
          size = remote.dig("census", "size") || remote["censusSize"]

          process.with_lock do
            attrs = {
              chain_id: remote["chainId"].to_s.presence || process.chain_id,
              vocdoni_upstream_id: remote["upstreamId"].to_s.presence || process.vocdoni_upstream_id,
              census_size: size.to_i.positive? ? size.to_i : process.census_size
            }

            questions_meta = extract_questions_meta(remote)
            new_metadata = process.metadata.merge("last_synced_at" => Time.current.iso8601)
            new_metadata["questions"] = questions_meta if questions_meta.any?
            new_metadata["saas_status"] = aggregate_status(remote)
            new_metadata["saas_published"] = remote["published"] == true
            attrs[:metadata] = new_metadata

            attrs[:state] = derive_state(remote)

            process.update!(attrs)
          end
        end

        # Enqueues the move Decidim asked for and the chain has not made (a lost
        # job, or one that gave up on a busy organization), unless that action
        # is still rescheduling itself.
        def reconcile!(remote)
          @divergences = process.published? ? divergences(remote) : {}
          @divergences.each do |key, enqueue|
            next if process.pending_action_live?(key)

            Rails.logger.info "[vocdoni] election ##{election.id}: #{key} not on chain yet; enqueuing it"
            enqueue.call
          end
        end

        # Pending-action key => enqueue lambda. An ended election only needs
        # the end, which also closes every question.
        def divergences(remote)
          statuses = Array(remote["questions"]).map { |q| q["status"].to_s.upcase }.compact_blank
          if settled?(election.end_at)
            return {} if statuses.all? { |status| TERMINAL_STATUSES.include?(status) }

            return { EndProcessOnChainJob::PENDING_KEY => -> { EndProcessOnChainJob.perform_later(election.id) } }
          end
          return {} unless election.per_question?

          question_divergences
        end

        # A question whose failure is still retrying (`retry_close`, `retry_on`)
        # is left to that loop, so loops do not multiply; see #retrying?.
        def question_divergences
          chain = process.questions_metadata.to_h { |row| [row["decidim_question_id"].to_i, row["vocdoni_status"].to_s.upcase] }

          election.questions.each_with_object({}) do |question, list|
            status = chain[question.id]
            next if status.blank? || TERMINAL_STATUSES.include?(status)
            next if retrying?(process.question_failures[question.id.to_s])

            action = question_action(question, status)
            next if action.nil?

            list[UpdateQuestionOnChainJob.pending_key(question.id, action)] = -> { UpdateQuestionOnChainJob.perform_later(question.id, action) }
          end
        end

        # The move a question needs past the grace, or nil when the chain agrees.
        def question_action(question, status)
          if question.published_results?
            "publish_results" if settled?(question.published_results_at)
          elsif settled?(question.voting_enabled_at) && UpdateQuestionOnChainJob::REACHED_STATUSES["READY"].exclude?(status)
            "enable_voting"
          end
        end

        # Not given up and written recently: an enable_voting failure never sets
        # `gave_up`, and its `retry_on` is over within a minute or two.
        def retrying?(failure)
          return false if failure.blank? || failure["gave_up"]

          at = Decidim::Elections::Vocdoni::Process.parse_time(failure["at"])
          at.present? && at > FAILURE_RETRY_WINDOW.ago
        end

        def settled?(time)
          time.present? && time <= RECONCILE_GRACE.ago
        end

        # `Process#state` reflects how far this election has gotten in the
        # Vocdoni lifecycle. It is not a straight copy of the SaaS status —
        # `publishing` collapses everything that is "created but not yet
        # visibly on chain", and `published` covers `READY`, `ONGOING`,
        # `PAUSED`, `ENDED` and `RESULTS`.
        def derive_state(remote)
          if remote["published"] == true
            "published"
          elsif process.failed?
            # A refused publish (a 402 from an empty wallet, say) leaves a
            # chainId on the draft: keep `failed` so the dashboard alert and
            # its retry button stay up, and stop polling.
            "failed"
          elsif remote["chainId"].to_s.present?
            # We already reached the chain but SaaS has not confirmed the
            # publish — keep waiting rather than downgrading to `pending`.
            "publishing"
          else
            process.state
          end
        end

        def extract_questions_meta(remote)
          Array(remote["questions"]).each_with_index.map do |upstream, index|
            local = election.questions[index]
            {
              "decidim_question_id" => local&.id,
              "vocdoni_question_id" => (upstream["id"] || upstream["questionId"]).to_s.presence,
              "vocdoni_upstream_id" => upstream["upstreamId"].to_s.presence,
              "vocdoni_status" => upstream["status"].to_s.presence
            }
          end
        end

        # Fires a `:one_shot` `SyncElectionResultsJob` on every tick while the
        # process is in an active voting window and the election opted in to
        # live results. Idempotent — the results job just writes the counter
        # to whatever the chain currently reports, and it does not
        # self-reschedule in one-shot mode so it cannot fork a second polling
        # loop.
        def sync_live_results!(remote)
          return unless election.results_availability.to_s == "real_time"
          return unless remote_active?(remote)
          return unless process.reload.published?

          Decidim::Elections::Vocdoni::SyncElectionResultsJob.perform_later(
            election.id, mode: :one_shot
          )
        end

        def reschedule_if_needed!(remote)
          delay = cadence_for(remote)
          return if delay.nil?

          self.class.set(wait: delay.seconds).perform_later(election.id)
        end

        def cadence_for(remote)
          state = process.reload.state
          return PUBLISHING_CADENCE_S if state == "publishing"
          # Keep checking until the chain catches up with Decidim.
          return IDLE_CADENCE_S if @divergences.present? && !remote_active?(remote)
          return nil unless remote_active?(remote)

          election.results_availability.to_s == "real_time" ? LIVE_CADENCE_S : IDLE_CADENCE_S
        end

        # `GET /processes/{id}` reports status per question, not for the
        # process as a whole — so we treat the process as active while any
        # question is still in one of the ACTIVE_STATUSES and the SaaS has
        # confirmed the publish.
        def remote_active?(remote)
          return false unless remote["published"] == true

          Array(remote["questions"]).any? do |q|
            ACTIVE_STATUSES.include?(q["status"].to_s.upcase)
          end
        end

        # Rolls the per-question statuses into a single label for the
        # sidecar's metadata so the admin dashboard has one thing to read.
        def aggregate_status(remote)
          statuses = Array(remote["questions"]).map { |q| q["status"].to_s.upcase }.compact_blank
          return nil if statuses.empty?
          return "ONGOING" if statuses.intersect?(ACTIVE_STATUSES)

          statuses.first
        end
      end
    end
  end
end
