# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Admin
        # Empties a "Participants from a file" census: the people go, the
        # census type stays, so the admin can upload another file.
        class RemoveCensusFile < Decidim::Command
          def initialize(election, user)
            @election = election
            @user = user
          end

          def call
            return broadcast(:invalid) unless election.editable?

            Decidim::Elections::Voter.transaction do
              election.voters.delete_all
              Decidim.traceability.update!(election, user, { census_settings: {} }, visibility: "admin-only")
            end
            PreflightTrigger.call(election.reload)

            broadcast(:ok)
          end

          private

          attr_reader :election, :user
        end
      end
    end
  end
end
