# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Removes the election from the public side of Decidim. The on-chain
      # process, if any, is unaffected — it keeps running and keeps accepting
      # votes from anyone holding a direct link, which is why the admin UI warns
      # about it.
      class UnpublishElection < Decidim::Command
        def initialize(election, current_user)
          @election = election
          @current_user = current_user
        end

        def call
          return broadcast(:invalid) unless election.published?

          transaction { unpublish_election }

          broadcast(:ok, election)
        end

        private

        attr_reader :election, :current_user

        def unpublish_election
          @election = Decidim.traceability.perform_action!(
            :unpublish,
            election,
            current_user,
            visibility: "all"
          ) do
            election.unpublish!
            election
          end
        end
      end
    end
  end
end
end
