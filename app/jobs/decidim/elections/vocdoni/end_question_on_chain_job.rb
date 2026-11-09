# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Enqueued from the `subscribe_to_question_publish_results` subscriber
      # when the admin clicks "Publish results" on a single question of a
      # per_question Vocdoni-backed election. Moves that question to `ENDED`
      # on chain so the sequencer decrypts its tally.
      #
      # `EndProcessOnChainJob` closes the whole election; this job closes one
      # question at a time, which is what `per_question` elections need.
      class EndQuestionOnChainJob < ApplicationJob
        queue_as :vocdoni

        retry_on Decidim::Elections::Vocdoni::ApiError, wait: :polynomially_longer, attempts: 3

        def perform(question_id)
          return unless load_question!(question_id)

          upstream_id = process.csp_elections.find_by(decidim_question_id: question.id)&.upstream_id
          return if upstream_id.blank?

          end_on_chain!(upstream_id)
          Decidim::Elections::Vocdoni::SyncElectionResultsJob.perform_later(election.id)
        rescue Decidim::Elections::Vocdoni::ApiError => e
          process&.record_failure!(redact(e.message), step: "end_question_on_chain", code: e.try(:code))
          raise if e.transient?
        end

        private

        attr_reader :question, :process

        # Loads the question, election and process into instance variables.
        # Returns false if any prerequisite is not met so `perform` can bail
        # early without branching on each condition.
        def load_question!(question_id)
          @question = Decidim::Elections::Question.find_by(id: question_id)
          return false if question.blank?

          @election = question.election
          @process = election.vocdoni_process
          return false if process.blank? || process.vocdoni_process_id.blank?
          return false unless process.published?

          Decidim::Elections::Vocdoni.validate_configuration!
          true
        end

        def end_on_chain!(upstream_id)
          response = client.elections.bulk_set_question_status(
            process.vocdoni_process_id,
            status: "ENDED",
            question_ids: [upstream_id]
          ).to_h
          await_job!(response["jobId"])
          Rails.logger.info "[vocdoni] moved question ##{question.id} to ENDED for election ##{election.id} (process #{process.vocdoni_process_id})"
        end
      end
    end
  end
end
