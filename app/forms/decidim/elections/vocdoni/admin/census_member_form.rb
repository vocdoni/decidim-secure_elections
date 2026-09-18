# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # One row of the census table.
      #
      # Only the columns the election actually needs are shown and validated —
      # asking for a national ID that no part of the flow will ever read is how
      # a census ends up half-filled. What the election *does* need is
      # required here, at entry time, rather than discovered when the upstream
      # group validation answers `40037` with a list of member ids.
      class CensusMemberForm < Decidim::Form
        mimic :census_member

        attribute :id, Integer
        attribute :name, String
        attribute :surname, String
        attribute :email, String
        attribute :phone, String
        attribute :member_number, String
        attribute :national_id, String
        attribute :birth_date, Decidim::Attributes::LocalizedDate
        attribute :weight, Integer

        # Set by the remove button of the inline table. A row the admin removed
        # before saving is not an error, it is simply gone.
        attribute :deleted, Boolean, default: false

        validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true, unless: :ignored?
        validates :weight,
                  numericality: { only_integer: true, greater_than: 0 },
                  allow_blank: true,
                  unless: :ignored?
        validate :required_fields_present, unless: :ignored?
        validate :one_alternative_present, unless: :ignored?
        validate :identifiable, unless: :ignored?

        def deleted?
          deleted.present?
        end

        # A row the admin removed, or a spare row they never filled in.
        # Offering an empty row to type into and then complaining that it is
        # empty would be absurd; an *existing* member emptied out is a
        # different matter and is reported by `identifiable`.
        def ignored?
          deleted? || (id.blank? && empty_row?)
        end

        def election
          @election ||= context[:election]
        end

        def to_param
          id.presence || "census-member-id"
        end

        # Reads a field by its upstream name, so callers never have to know
        # that `memberNumber` is stored as `member_number`.
        def value_for(field)
          attribute = Vocdoni::CensusMember.attribute_for(field)
          attribute && public_send(attribute)
        end

        # Nothing was typed into this row. Deliberately not called `blank?`:
        # overriding that on a form object changes what `present?` means for
        # every caller, including ActiveSupport's own.
        def empty_row?
          Vocdoni::CensusMember::EDITABLE_FIELDS.all? { |field| value_for(field).blank? }
        end

        private

        def required_fields
          election ? election.required_member_fields : []
        end

        def required_fields_present
          required_fields.each do |field|
            next if value_for(field).present?

            errors.add(Vocdoni::CensusMember.attribute_for(field), :blank)
          end
        end

        # "Voter's choice" 2FA needs one contact, not both.
        def one_alternative_present
          alternatives = election ? election.alternative_member_fields : []
          return if alternatives.empty?
          return if alternatives.any? { |field| value_for(field).present? }

          errors.add(Vocdoni::CensusMember.attribute_for(alternatives.first), :blank)
        end

        def identifiable
          return unless empty_row?

          errors.add(:base, :blank_member)
        end
      end
    end
  end
end
end
