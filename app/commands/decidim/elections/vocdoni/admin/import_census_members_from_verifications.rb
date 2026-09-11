# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Builds the census from participants who hold a Decidim verification.
      #
      # This is the source the Vocdoni app cannot offer, and the reason the
      # module exists: an organization that has already verified its
      # participants should not have to export them and upload them back.
      #
      # Decidim knows a participant's name and email, so those are the fields
      # that get filled in. If the election authenticates on something else the
      # members table will show the rows as incomplete — visible now, rather
      # than as an upstream `40037` at publish time.
      class ImportCensusMembersFromVerifications < Decidim::Command
        # @param form [Decidim::Elections::Vocdoni::Admin::CensusVerificationsForm]
        # @param election [Decidim::Elections::Vocdoni::Election]
        # @param current_user [Decidim::User]
        def initialize(form, election, current_user)
          @form = form
          @election = election
          @current_user = current_user
        end

        def call
          return broadcast(:invalid) unless election.editable?
          return broadcast(:invalid) if form.invalid?

          imported = 0

          transaction do
            election.census_members.destroy_all if form.replace
            imported = import_members
            election.refresh_census_size!
            log_change
          end

          broadcast(:ok, imported)
        end

        private

        attr_reader :form, :election, :current_user

        def import_members
          # Re-running the import must not double anyone up. Email is the only
          # key Decidim has for a participant.
          seen = election.census_members.pluck(:email).compact_blank.to_set(&:downcase)
          imported = 0

          form.participants.to_member_attributes.each do |attributes|
            email = attributes[:email].to_s.downcase.presence
            next if email && seen.include?(email)

            seen << email if email
            election.census_members.create!(attributes)
            imported += 1
          end

          imported
        end

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
