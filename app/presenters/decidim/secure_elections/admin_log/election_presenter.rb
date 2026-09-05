# frozen_string_literal: true

module Decidim
  module SecureElections
    module AdminLog
      # Presents a `Decidim::SecureElections::Election` in the admin log.
      class ElectionPresenter < Decidim::Log::BasePresenter
        private

        def action_string
          case action
          when "create", "update", "soft_delete", "restore", "publish", "unpublish", "setup", "update_census", "update_calendar", "update_status"
            "decidim.secure_elections.admin_log.election.#{action}"
          else
            super
          end
        end

        def diff_fields_mapping
          {
            title: :i18n,
            description: :i18n,
            start_at: :date,
            end_at: :date,
            published_at: :date,
            status: :string,
            census_group_id: :string,
            census_auth_fields: :string,
            census_two_fa_fields: :string
          }
        end
      end
    end
  end
end
