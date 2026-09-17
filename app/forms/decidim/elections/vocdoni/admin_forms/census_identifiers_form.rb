# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module AdminForms
        # Changing the details voters type, for a list that is already
        # imported — the "Change" link on the Census tab, which must not force
        # the admin to upload the file again.
        #
        # Same rules as the wizard's last step ({ChoosesIdentifiers}); only the
        # source differs: the rows are in the database rather than in a file
        # about to be read.
        class CensusIdentifiersForm < Decidim::Form
          include ChoosesIdentifiers

          mimic :census_identifiers

          attribute :election, Object

          def self.from_model(election)
            new(election:, identifiers: Array(election.census_settings.to_h["identifiers"]).map(&:to_s))
          end

          # The controller passes the election in the form's context, not as an
          # attribute; read both, or every rule below is skipped on save.
          def election
            super || (context[:election] if context)
          end

          # Every column the list kept. A list imported with upstream's own
          # importer has no stored columns, so its rows answer for it.
          def available_fields
            return [] if election.blank?

            @available_fields ||= begin
              stored = Array(election.census_settings.to_h["fields"]).map(&:to_s)
              stored = voter_keys if stored.empty?
              stored & CensusCsv::Fields::TARGETS
            end
          end

          def identifiers_checkable?
            election.present? && available_fields.any?
          end

          # How many people on the list have nothing in that column — the
          # answer to "what happens to the members without an email?", given
          # before the choice rather than after it.
          def people_without(field)
            return 0 if election.blank?

            ::Decidim::Elections::Voter.where(election:)
                                       .where("coalesce(data->>?, '') = ''", field)
                                       .count
          end

          private

          def voter_keys
            ::Decidim::Elections::Voter.where(election:).first&.data.to_h.keys.map(&:to_s) || []
          end

          # Counted in the database: the same comparison the voter sign-in form
          # makes, which stores its values already cleaned.
          def identifier_duplicates(chosen)
            return 0 if chosen.empty?

            connection = ::Decidim::Elections::Voter.connection
            keys = chosen.map { |field| "lower(data->>#{connection.quote(field)})" }
            ::Decidim::Elections::Voter.where(election:)
                                       .group(Arel.sql(keys.join(", ")))
                                       .having("count(*) > 1")
                                       .count
                                       .values
                                       .sum
          end
        end
      end
    end
  end
end
