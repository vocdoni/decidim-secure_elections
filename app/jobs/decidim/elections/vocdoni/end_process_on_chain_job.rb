# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Enqueued from the `subscribe_to_end` subscriber when the admin clicks
      # "End election" on a Vocdoni-backed election. Upstream's `UpdateElectionStatus`
      # only writes `election.end_at = Time.current` in Decidim's own tables — the
      # on-chain process keeps running until its scheduled `endDate`, so the
      # explorer keeps saying "Voting open / Provisional" and `finalResults`
      # stays false.
      #
      # A Vocdoni process is a bundle of questions and each question is its own
      # Vochain election, so "ending the whole election" means moving every
      # question to status `ENDED`. `PUT /processes/{id}/questions/status` with
      # no `questions[]` targets every published question of the process —
      # exactly the semantics we want here.
      #
      # After the async move confirms, the sidecar is out of date (SaaS status
      # jumped from ONGOING to ENDED/RESULTS); enqueue a `SyncProcessJob` so the
      # dashboard reflects reality on the next poll cycle. `SyncElectionResultsJob`
      # is also enqueued here — for a `secretUntilTheEnd` election the chain
      # only decrypts and publishes the tally *after* the ENDED transition, and
      # the job self-schedules until `finalResults: true`, so the counter is
      # ready by the time the admin clicks "Publish results".
      class EndProcessOnChainJob < ApplicationJob
        queue_as :vocdoni

        retry_on Decidim::Elections::Vocdoni::ApiError, wait: :polynomially_longer, attempts: 3

        def perform(election_id)
          @election = Decidim::Elections::Election.find_by(id: election_id)
          return if election.blank?

          @process = election.vocdoni_process
          return if process.blank? || process.vocdoni_process_id.blank?
          # Nothing to end on chain if the process never made it there. A
          # sidecar still in `pending`, `publishing` or `failed` has no
          # questions in `READY`/`ONGOING` for the SaaS to move to `ENDED`.
          return unless process.published?

          Decidim::Elections::Vocdoni.validate_configuration!

          response = client.elections.bulk_set_question_status(
            process.vocdoni_process_id,
            status: "ENDED"
          ).to_h
          await_job!(response["jobId"])

          Rails.logger.info "[vocdoni] moved every question to ENDED for election ##{election.id} (process #{process.vocdoni_process_id})"

          Decidim::Elections::Vocdoni::SyncProcessJob.perform_later(election.id)
          Decidim::Elections::Vocdoni::SyncElectionResultsJob.perform_later(election.id)
        rescue Decidim::Elections::Vocdoni::ApiError => e
          process&.record_failure!(redact(e.message), step: "end_on_chain", code: e.try(:code))
          raise if e.transient?
        end

        private

        attr_reader :process
      end
    end
  end
end
