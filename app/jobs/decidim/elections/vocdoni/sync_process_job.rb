# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Polls the Vocdoni SaaS for the on-chain state of a published process
      # and mirrors it into the {Process} sidecar so the admin dashboard and
      # the voter booth do not each have to call the API.
      #
      # Enqueued from {PublishToVocdoniJob} right after `POST /processes` and
      # again from itself while the process is still `publishing`, so a
      # deferred SaaS confirmation (the "publish did not confirm all questions
      # after 3 rounds" case) resolves without a human refreshing anything.
      # A process that has transitioned to `published`, `ongoing`, `ended` or
      # `results` is checked less often to keep the load light — the same
      # cadence the results-tally job uses.
      class SyncProcessJob < ApplicationJob
        queue_as :vocdoni_spike

        retry_on Decidim::Elections::Vocdoni::ApiError, wait: :polynomially_longer, attempts: 3

        # Cadence for the self-scheduled follow-up:
        #   pending / publishing → 30s so a slow SaaS confirmation lands soon
        #   ongoing / paused     → 5 min for turnout / status changes
        #   ended / results      → done, no rescheduling
        DEFAULT_CADENCE_S = {
          "publishing" => 30,
          "ongoing"    => 300,
          "paused"     => 300
        }.freeze

        def perform(election_id)
          @election = Decidim::Elections::Election.find_by(id: election_id)
          return if election.blank?

          @process = election.vocdoni_process
          return if process.blank? || process.vocdoni_process_id.blank?

          Decidim::Elections::Vocdoni.validate_configuration!

          remote = client.elections.get(process.vocdoni_process_id).to_h
          persist!(remote)
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
          new_metadata["saas_status"] = remote["status"].to_s.presence
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
              "vocdoni_status"      => upstream["status"].to_s.presence
            }
          end
        end

        def reschedule_if_needed!(_remote)
          delay = DEFAULT_CADENCE_S[process.reload.state]
          return if delay.blank?

          self.class.set(wait: delay.seconds).perform_later(election.id)
        end
      end
    end
  end
end
