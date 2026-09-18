# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Moves questions of an on-chain election between states. Applied through
      # `SetQuestionStatusJob`; never from the request itself.
      class QuestionStatusForm < Decidim::Form
        mimic :question_status

        # `results` is produced by the chain when the tally is published, so it
        # is not something an admin sets from here.
        ALLOWED_STATUSES = %w(ready paused ended canceled).freeze

        attribute :status, String
        attribute :question_ids, [Integer]

        validates :status, presence: true, inclusion: { in: ALLOWED_STATUSES }
        validate :election_is_on_chain
        validate :questions_belong_to_election

        def election
          @election ||= context[:election]
        end

        # `nil` means "every question of the process", which is what the API
        # expects when `questionIds` is omitted.
        def selected_question_ids
          ids = Array(question_ids).compact_blank
          ids.presence
        end

        private

        def election_is_on_chain
          return if election&.on_chain?

          errors.add(:base, I18n.t("decidim.elections.vocdoni.admin.monitor.errors.not_on_chain"))
        end

        def questions_belong_to_election
          return if election.blank?
          return if selected_question_ids.blank?

          known = election.questions.where(id: selected_question_ids).pluck(:id)
          return if (selected_question_ids - known).empty?

          errors.add(:question_ids, :invalid)
        end
      end
    end
  end
end
end
