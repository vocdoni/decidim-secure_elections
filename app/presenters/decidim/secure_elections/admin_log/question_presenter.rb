# frozen_string_literal: true

module Decidim
  module SecureElections
    module AdminLog
      # Presents a `Decidim::SecureElections::Question` in the admin log.
      class QuestionPresenter < Decidim::Log::BasePresenter
        private

        def action_string
          case action
          when "create", "update", "delete", "update_status"
            "decidim.secure_elections.admin_log.question.#{action}"
          else
            super
          end
        end

        def diff_fields_mapping
          {
            body: :i18n,
            description: :i18n,
            question_type: :string,
            max_choices: :integer,
            min_choices: :integer,
            secret_until_the_end: :boolean,
            position: :integer,
            vocdoni_status: :string
          }
        end
      end
    end
  end
end
