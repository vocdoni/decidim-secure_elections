# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Saves the voter-authentication settings of an election.
      #
      # Nothing is sent upstream: the census reaches Vocdoni only when the
      # election is published, from a background job that creates the members,
      # the group and the census in that order (ARCHITECTURE §4c). In particular
      # `census_group_id` is never written here — it is a cache the job fills
      # in, and it must never be shown to or asked of an admin.
      class UpdateElectionCensus < Decidim::Commands::UpdateResource
        private

        alias election resource

        def invalid?
          return true unless election.editable?

          form.invalid?
        end

        def attributes
          @attributes ||= {
            census_auth_fields: form.auth_fields,
            census_two_fa_fields: form.two_fa_fields,
            weighted: form.weighted
          }
        end

        def run_after_hooks
          election.refresh_census_size!
        end

        def extra_params = { visibility: "admin-only" }
      end
    end
  end
end
end
