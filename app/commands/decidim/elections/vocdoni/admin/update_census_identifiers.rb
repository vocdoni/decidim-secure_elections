# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Admin
        # Changes the details voters type to be found on an imported list,
        # without touching the list itself ("Change" on the Census tab).
        #
        # The choice is part of the census, so a secret vote has to be checked
        # against Vocdoni again: the identifiers become its `authFields`.
        class UpdateCensusIdentifiers < Decidim::Command
          # @param form     [AdminForms::CensusIdentifiersForm]
          # @param election [Decidim::Elections::Election]
          # @param user     [Decidim::User]
          def initialize(form, election, user)
            @form = form
            @election = election
            @user = user
          end

          def call
            return broadcast(:invalid) if form.invalid? || !election.editable?

            Decidim.traceability.update!(
              election,
              user,
              { census_settings: election.census_settings.to_h.merge("identifiers" => form.chosen_identifiers) },
              visibility: "admin-only"
            )
            PreflightTrigger.call(election.reload)

            broadcast(:ok)
          end

          private

          attr_reader :form, :election, :user
        end
      end
    end
  end
end
