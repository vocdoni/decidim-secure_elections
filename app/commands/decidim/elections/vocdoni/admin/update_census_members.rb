# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Saves the census table: creates the new rows, updates the edited ones
      # and deletes the removed ones, in a single transaction.
      #
      # All or nothing on purpose. A partially saved table would leave the
      # admin looking at a screen that no longer matches the database, and a
      # census is precisely the thing that must not be half-right.
      class UpdateCensusMembers < Decidim::Command
        # @param form [Decidim::Elections::Vocdoni::Admin::CensusMembersForm]
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

          transaction do
            destroy_removed
            persist_kept
            refresh_census_size
            log_change
          end

          broadcast(:ok, election)
        rescue ActiveRecord::RecordInvalid
          broadcast(:invalid)
        end

        private

        attr_reader :form, :election, :current_user

        def destroy_removed
          return if form.deleted_ids.empty?

          election.census_members.where(id: form.deleted_ids).destroy_all
        end

        def persist_kept
          form.kept_members.each do |member_form|
            member = find_or_build(member_form)
            member.assign_attributes(attributes_for(member_form))
            member.save!
          end
        end

        def find_or_build(member_form)
          return election.census_members.build if member_form.id.blank?

          election.census_members.find(member_form.id)
        end

        # Every field is assigned, blanks included: clearing a cell has to
        # actually clear it. Fields the election does not use round-trip
        # through hidden inputs, so nothing is lost by not being on screen.
        def attributes_for(member_form)
          attributes = Vocdoni::CensusMember::EDITABLE_FIELDS.to_h do |field|
            [Vocdoni::CensusMember.attribute_for(field), member_form.value_for(field)]
          end

          # Voting power has a floor rather than a blank: a member who counts
          # zero is not a member.
          attributes[:weight] = member_form.weight.to_i.positive? ? member_form.weight : 1
          attributes
        end

        def refresh_census_size
          election.refresh_census_size!
        end

        # Logged against the election rather than each member: what an admin
        # audit needs to know is that the electorate changed and who changed it.
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
