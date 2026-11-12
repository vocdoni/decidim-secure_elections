# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Mirrors a per-question admin action onto that question's own Vochain
      # election. A `per_question` process is published with every question
      # `PAUSED`:
      #
      # * `enable_voting`   — the question goes `READY`, so ballots land.
      # * `publish_results` — the question goes `ENDED`, which closes it and
      #   makes the chain reveal its encrypted tally; the tally is then pulled
      #   into Decidim for that question only.
      #
      # Enqueued from the `subscribe_to_question_status` subscriber and from
      # {PublishElectionJob}, which replays actions taken before the process
      # reached the chain.
      class UpdateQuestionOnChainJob < ApplicationJob
        queue_as :vocdoni

        retry_on Decidim::Elections::Vocdoni::ApiError, wait: :polynomially_longer, attempts: 3

        TARGET_STATUS = {
          "enable_voting" => "READY",
          "publish_results" => "ENDED"
        }.freeze

        def perform(question_id, action)
          status = TARGET_STATUS[action.to_s]
          raise ArgumentError, "Unknown question action #{action.inspect}" if status.nil?

          question = Decidim::Elections::Question.find_by(id: question_id)
          vocdoni_question_id = question && on_chain_id(question)
          return if vocdoni_question_id.blank?

          Decidim::Elections::Vocdoni.validate_configuration!

          response = client.elections.bulk_set_question_status(
            process.vocdoni_process_id, status:, question_ids: [vocdoni_question_id]
          ).to_h
          await_job!(response["jobId"])

          Rails.logger.info "[vocdoni] moved question ##{question.id} of election ##{election.id} to #{status}"

          # No SyncProcessJob here: one is already looping while voting is
          # open, and each enqueue would start another loop.
          return unless status == "ENDED"

          Decidim::Elections::Vocdoni::SyncElectionResultsJob.perform_later(election.id, question_ids: [question.id])
        rescue Decidim::Elections::Vocdoni::ApiError => e
          # The other questions keep voting, so the process is not marked failed.
          process&.record_failure!(redact(e.message), step: "question_#{action}", code: e.try(:code), keep_state: true)
          raise if e.transient?
        end

        private

        attr_reader :process

        # The question's SaaS id, or nil while the process is not on chain:
        # PublishElectionJob replays the action once it is.
        def on_chain_id(question)
          @election = question.election
          @process = election.vocdoni_process
          return nil if process.blank? || !process.published? || process.vocdoni_process_id.blank?

          row = process.questions_metadata.find { |meta| meta["decidim_question_id"].to_i == question.id }
          row.to_h["vocdoni_question_id"].presence
        end
      end
    end
  end
end
