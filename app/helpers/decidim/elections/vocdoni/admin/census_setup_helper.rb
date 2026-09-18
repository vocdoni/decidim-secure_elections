# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Admin
        # Turns Decidim's verification vocabulary into something an organiser
        # reads, and keeps the one-line description of a census in a single
        # place, so the Census tab and the Security tab say the same thing
        # about the same list.
        module CensusSetupHelper
          SCOPE = "decidim.elections.vocdoni.admin.census_setup"

          # Who does the checking. Decidim's own labels ("Direct" and
          # "Multi-Step") describe how a verification is built, not what it
          # costs the organiser, and for one of them the two disagree:
          # `csv_census` is an engine with its own steps, yet nobody reviews
          # anything: a person is matched against a list that was uploaded
          # once. So the ones Decidim ships are named here, and anything else
          # falls back to the only signal available.
          KINDS = {
            "id_documents" => "reviewed",
            "postal_letter" => "reviewed",
            "csv_census" => "automatic"
          }.freeze

          # @return ["automatic", "reviewed"]
          def verification_kind(workflow)
            KINDS.fetch(workflow.name.to_s) { workflow.form.present? ? "automatic" : "reviewed" }
          end

          def verification_kind_label(workflow)
            t("verifications.kinds.#{verification_kind(workflow)}", scope: SCOPE)
          end

          # Our own plain-words line for the verifications Decidim ships, then
          # whatever explanation the workflow carries, then nothing rather than
          # a key.
          def verification_description(workflow)
            name = workflow.name.to_s
            own = t("verifications.descriptions.#{name}", scope: SCOPE, default: "")
            return own if own.present?

            t("decidim.authorization_handlers.#{name}.explanation", default: "")
          end

          def verification_name(workflow)
            workflow.fullname.presence || workflow.name.to_s.humanize
          end

          # The details a voter of a file census types to be found on the list.
          # @return [Array<String>] canonical field ids, in file order.
          def census_identifiers(election)
            fields = Array(election.census_settings.to_h["fields"]).map(&:to_s)
            fields = census_columns(election) if fields.empty?
            fields & Array(election.census_settings.to_h["identifiers"]).map(&:to_s)
          end

          def census_identifier_labels(election)
            census_identifiers(election).map { |field| CensusCsv::Fields.label(field) }
          end

          # Every column the file kept. A list imported with upstream's own
          # importer has no stored columns; its rows carry the keys.
          def census_columns(election)
            stored = Array(election.census_settings.to_h["fields"]).map(&:to_s)
            return stored if stored.any?

            first = ::Decidim::Elections::Voter.where(election:).first
            (first&.data.to_h.keys.map(&:to_s) || []) & CensusCsv::Fields::TARGETS
          end
        end
      end
    end
  end
end
