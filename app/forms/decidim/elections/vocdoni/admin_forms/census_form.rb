# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module AdminForms
        # Form for the "Secure via Vocdoni" census manifest. Registered by
        # the main engine on `Decidim::Elections.census_registry` and rendered
        # in the upstream Census admin tab.
        #
        # `#census_settings` is what upstream's `ProcessCensus` command picks
        # up and persists into `election.census_settings` (a jsonb column on
        # `decidim_elections_elections`). The form fields themselves stay
        # backend-agnostic — a Vocdoni backend collects a set of identifier
        # fields from voters and optionally makes the ballot weighted.
        class CensusForm < Decidim::Form
          mimic :census
          include Decidim::AttributeObject::TypeMap

          # Identifier fields we collect from every voter at CSP auth time.
          # Superset from which admin picks one or more. The list itself is
          # frozen; only the *selection* is form input.
          CREDENTIAL_FIELDS = %w(email phone member_number national_id name date_of_birth).freeze

          attribute :credential_fields, Array[String], default: []
          attribute :weighted_votes, Boolean, default: false

          validate :at_least_one_credential_field
          validates :credential_fields, inclusion: { in: CREDENTIAL_FIELDS }, allow_blank: true

          def self.from_params(params, additional_params = {})
            instance = super(params, additional_params)
            # Params may arrive as { credential_fields: { email: "1", phone: "0", ... } }
            # (form_for check_box style) — normalise to an array of truthy keys.
            raw = params.respond_to?(:dig) ? params.dig(:credential_fields) : nil
            if raw.is_a?(Hash) || raw.is_a?(ActionController::Parameters)
              instance.credential_fields = raw.select { |_k, v| ActiveModel::Type::Boolean.new.cast(v) }.keys.map(&:to_s)
            end
            instance
          end

          # Hash written into `election.census_settings` (upstream jsonb) by
          # upstream's ProcessCensus command. Round-trips: `from_params(hash)`
          # on subsequent edits rebuilds the same field selections.
          def census_settings
            {
              "credential_fields" => credential_fields.map(&:to_s),
              "weighted_votes" => weighted_votes
            }
          end

          def credential_field?(field)
            credential_fields.include?(field.to_s)
          end

          private

          def at_least_one_credential_field
            return unless credential_fields.empty?

            errors.add(:credential_fields, :blank)
          end
        end
      end
    end
  end
end
