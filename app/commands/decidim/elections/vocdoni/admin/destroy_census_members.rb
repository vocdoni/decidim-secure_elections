# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Empties the census.
      #
      # Only possible while the election is still off chain. Once the process
      # exists on Vocdoni the census it was published with is fixed there, and
      # clearing the local copy would only make Decidim lie about who may vote.
      class DestroyCensusMembers < Decidim::Command
        # @param election [Decidim::Elections::Vocdoni::Election]
        # @param current_user [Decidim::User]
        def initialize(election, current_user)
          @election = election
          @current_user = current_user
        end

        def call
          return broadcast(:invalid) unless election.editable?

          count = election.census_members.count
          return broadcast(:invalid) if count.zero?

          transaction do
            election.census_members.destroy_all
            election.refresh_census_size!
            log_change
          end

          broadcast(:ok, count)
        end

        private

        attr_reader :election, :current_user

        def log_change
          Decidim.traceability.perform_action!(:update_census, election, current_user, visibility: "admin-only") do
            election
          end
        end
      end
    end
  end
end
end
