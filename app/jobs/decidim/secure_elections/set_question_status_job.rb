# frozen_string_literal: true

module Decidim
  module SecureElections
    # Moves questions of a live process between states (pause, resume, end,
    # cancel).
    #
    # `PUT /processes/{id}/questions/status` is asynchronous: it answers with a
    # job id that has to be polled. That polling is exactly why this cannot live
    # in a controller action.
    class SetQuestionStatusJob < ApplicationJob
      queue_as :vocdoni

      retry_on Decidim::SecureElections::ApiError, wait: :polynomially_longer, attempts: 3

      # @param election_id [Integer]
      # @param status [String] one of Question::STATUSES, case-insensitive
      # @param question_ids [Array<Integer>, nil] local question ids; nil means
      #   every question of the process
      def perform(election_id, status, question_ids = nil)
        @election = Decidim::SecureElections::Election.find_by(id: election_id)
        return if election.blank? || election.vocdoni_process_id.blank?

        @status = status.to_s.downcase
        return unless Decidim::SecureElections::Question::STATUSES.include?(@status)

        Decidim::SecureElections.validate_configuration!

        @questions = resolve_questions(question_ids)
        return if @questions.empty?

        apply_upstream!
        persist_locally!

        Decidim::SecureElections::SyncResultsJob.perform_later(election.id)
      rescue StandardError => e
        record_failure!(election, e)
        raise
      end

      private

      attr_reader :status, :questions

      def resolve_questions(question_ids)
        ids = Array(question_ids).compact_blank
        return election.questions.to_a if ids.empty?

        election.questions.where(id: ids).to_a
      end

      # Whether the whole process, rather than a subset, is being moved.
      def whole_process?
        questions.size == election.questions.size
      end

      def apply_upstream!
        # `question_ids: nil` means "all questions" upstream, which is both
        # cheaper and less error-prone than enumerating them.
        upstream_ids = whole_process? ? nil : questions.filter_map { |question| question.vocdoni_question_id.presence }

        response = client.elections.bulk_set_question_status(
          election.vocdoni_process_id,
          # The API speaks uppercase; we store lowercase.
          status: status.upcase,
          question_ids: upstream_ids
        ).to_h

        await_job!(response["jobId"])
      end

      def persist_locally!
        Decidim::SecureElections::Election.transaction do
          Decidim::SecureElections::Question.where(id: questions.map(&:id)).update_all(vocdoni_status: status, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations

          next unless whole_process?
          next unless Decidim::SecureElections::Election::STATUSES.include?(status)

          election.update!(status:)
        end
      end
    end
  end
end
