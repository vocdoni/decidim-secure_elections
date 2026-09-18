# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module AdminLog
      # Presents a `Decidim::Elections::Vocdoni::Answer` in the admin log.
      class AnswerPresenter < Decidim::Log::BasePresenter
        private

        def action_string
          case action
          when "create", "update", "delete"
            "decidim.elections.vocdoni.admin_log.answer.#{action}"
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
end
