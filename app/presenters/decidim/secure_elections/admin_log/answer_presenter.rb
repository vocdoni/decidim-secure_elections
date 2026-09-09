# frozen_string_literal: true

module Decidim
  module SecureElections
    module AdminLog
      # Presents a `Decidim::SecureElections::Answer` in the admin log.
      class AnswerPresenter < Decidim::Log::BasePresenter
        private

        def action_string
          case action
          when "create", "update", "delete"
            "decidim.secure_elections.admin_log.answer.#{action}"
          else
            super
          end
        end

        def diff_fields_mapping
          {
            body: :i18n,
            value: :integer,
            position: :integer
          }
        end
      end
    end
  end
end
