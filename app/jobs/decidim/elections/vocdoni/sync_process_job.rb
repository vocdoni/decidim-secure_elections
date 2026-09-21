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
      #   `IDLE_CADENCE_S` otherwise. The faster tick for `real_time` is what
      #   keeps `response_options.votes_count` fresh: on every tick, if the
      #   election opted in, this job also fires a `SyncElectionResultsJob`
      #   in `:one_shot` mode (no self-reschedule — the outer loop is here).
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

        # Faster cadence during active voting when the election is
        # `results_availability: "real_time"`. Bounds the visible lag between
        # a voter casting a ballot and Decidim's public results view
        # reflecting the new count. Same tick rate the Vocdoni explorer at
        # `explorer.vote` uses against the chain API — enough to feel live
        # without hammering the SaaS. One anonymous GET on the cache-friendly
        # public endpoint per tick.
        #
        # A lower-latency alternative that we deliberately did NOT take:
        # poll the Vochain node directly at `api-{env}.vocdoni.net/v2/
        # elections/{upstreamId}` — the chain returns fresh data within
        # ~2-5 s of the vote block, bypassing whatever cache TTL sits on the
        # SaaS. It costs one call per question per tick instead of one per
        # process, and needs a second base URL in configuration. Worth
        # revisiting if 10-15 s turns out too laggy in practice for real_time
        # elections.
        LIVE_CADENCE_S = 10

        # SaaS statuses that mean the voting window is still open. Match on
        # upcase because the SaaS spells them upper. `GET /processes/{id}`
        # returns this per-question, not process-wide: a process is treated
        # as active while ANY question is still in one of these states.
        ACTIVE_STATUSES = %w(READY ONGOING PAUSED).freeze

        def perform(election_id)
          @election = Decidim::Elections::Election.find_by(id: election_id)
          return if election.blank?

          @process = election.vocdoni_process
          return if process.blank? || process.vocdoni_process_id.blank?

          Decidim::Elections::Vocdoni.validate_configuration!

          remote = client.elections.get(process.vocdoni_process_id).to_h
          persist!(remote)
          sync_live_results!(remote)
          reschedule_if_needed!(remote)
        rescue Decidim::Elections::Vocdoni::ApiError => e
          # Transient errors are retried by ActiveJob; a permanent 4xx is
          # recorded on the sidecar so the admin dashboard can surface it.
          process&.record_failure!(redact(e.message), step: "sync") unless e.transient?
          raise
        end

        private

        attr_reader :process

        # Merges the on-chain state into the sidecar. Any of these fields may
        # be missing on a given call — the SaaS fills them in as the on-chain
        # confirmation lands.
        def persist!(remote)
          size = remote.dig("census", "size") || remote["censusSize"]

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

        # `Process#state` reflects how far this election has gotten in the
        # Vocdoni lifecycle. It is not a straight copy of the SaaS status —
        # `publishing` collapses everything that is "created but not yet
        # visibly on chain", and `published` covers `READY`, `ONGOING`,
        # `PAUSED`, `ENDED` and `RESULTS`.
        def derive_state(remote)
          if remote["published"] == true
            "published"
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
          return "ONGOING" if statuses.any? { |s| ACTIVE_STATUSES.include?(s) }

          statuses.first
        end
      end
    end
  end
end
