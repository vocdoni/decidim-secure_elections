# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Makes the election visible on the public side of Decidim.
      #
      # This is *not* the blockchain publication — see `SetupElection` for that.
      # This one is reversible.
      class PublishElection < Decidim::Command
        def initialize(election, current_user)
          @election = election
          @current_user = current_user
        end

        def call
          return broadcast(:invalid) if election.published?

          transaction { publish_election }

          broadcast(:ok, election)
        end

        private

        attr_reader :election, :current_user

        def publish_election
          @election = Decidim.traceability.perform_action!(
            :publish,
            election,
            current_user,
            visibility: "all"
          ) do
            election.publish!
            election
          end
        end
      end
    end
  end
end
end
