# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # The whole census table, saved in one go.
      #
      # Rows are added and removed in the browser and submitted together, so
      # the admin never waits for a page load between "add a person" and "add
      # another" — the single biggest friction in the wizard this replaces.
      # Without JavaScript the same form still works: existing rows are
      # editable, blank rows can be filled in, and a row is removed by ticking
      # its "remove" box and saving.
      class CensusMembersForm < Decidim::Form
        mimic :census

        # Each row validates itself: Decidim adds a nested validator for an
        # array of forms automatically, and `Form#valid?` fails the parent when
        # any child has errors. That is what lets the table highlight the
        # offending cell rather than saying "something is wrong".
        attribute :members, [CensusMemberForm]

        validate :no_duplicates

        def election
          @election ||= context[:election]
        end

        def map_model(election)
          self.members = election.census_members.map do |member|
            CensusMemberForm.from_model(member).with_context(election:)
          end
        end

        # Rows the admin actually means to keep. A row that was added and left
        # completely empty is discarded rather than reported: adding a spare
        # row and not using it is not a mistake.
        def kept_members
          members.reject { |member| member.deleted? || (member.id.blank? && member.empty_row?) }
        end

        def deleted_ids
          members.select { |member| member.deleted? && member.id.present? }.map(&:id)
        end

        private

        # Two rows with the same email are two ballots for one person. The
        # census matches voters on these values, so a duplicate is either a
        # double vote or an authentication that resolves to the wrong row.
        def no_duplicates
          duplicate_fields.each do |field|
            attribute = Vocdoni::CensusMember.attribute_for(field)
            values = kept_members.filter_map { |member| member.value_for(field).to_s.strip.downcase.presence }
            next if values.uniq.size == values.size

            errors.add(:members, :duplicated_field, field: Vocdoni::CensusMember.field_label(field))
            kept_members.each do |member|
              value = member.value_for(field).to_s.strip.downcase
              member.errors.add(attribute, :taken) if value.present? && values.count(value) > 1
            end
          end
        end

        # Only the fields the election authenticates on have to be unique —
        # two people can share a household phone as long as nothing resolves a
        # voter by it.
        def duplicate_fields
          return [] if election.blank?

          election.census_fields & Vocdoni::CensusMember::EDITABLE_FIELDS
        end
      end
    end
  end
end
end
