# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Requests a status change for some or all questions of an on-chain
      # election. The API call and its async job polling happen in
      # `Decidim::Elections::Vocdoni::SetQuestionStatusJob`.
      class UpdateQuestionStatus < Decidim::Command
        def initialize(form, current_user)
          @form = form
          @current_user = current_user
        end

        def call
          return broadcast(:invalid) if form.invalid?

          Decidim.traceability.perform_action!(
            :update_status,
            election,
            current_user,
            visibility: "admin-only",
            requested_status: form.status
          )

          Decidim::Elections::Vocdoni::SetQuestionStatusJob.perform_later(
            election.id,
            form.status,
            form.selected_question_ids
          )

          broadcast(:ok, election)
        end

        private

        attr_reader :form, :current_user

        delegate :election, to: :form
      end
    end
  end
end
end
