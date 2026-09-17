# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module VoterForms
        # How a person on a "Participants from a file" census signs in to a
        # simple (non-Vocdoni) vote: they type the details the admin chose on
        # the Security tab, e.g. name and ID number.
        #
        # A person is found only when every detail matches exactly one line
        # of the file (case and extra spaces ignored). No match, a partial
        # match and an ambiguous match all fail the same way, so the page never
        # hints at which detail was wrong.
        class CensusFileForm < Decidim::Form
          mimic :census_file_voter

          attribute :values, { String => String }

          validate :census_match

          def election
            @election ||= context[:election]
          end

          def identifiers
            return [] if election.blank?

            Array(election.census_settings.to_h["identifiers"]).map(&:to_s) & CensusCsv::Fields::SIMPLE_IDENTIFIERS
          end

          def value_for(field)
            values.to_h[field].to_s
          end

          def voter_uid
            census_voter&.to_global_id&.to_s
          end

          def census_voter
            return @census_voter if defined?(@census_voter)

            @census_voter = find_census_voter
          end

          private

          def find_census_voter
            return nil if election.blank? || identifiers.empty?

            wanted = identifiers.index_with { |field| CensusCsv::Fields.comparable(field, value_for(field)) }
            return nil if wanted.values.any?(&:blank?)

            scope = identifiers.reduce(Decidim::Elections::Voter.where(election:)) do |relation, field|
              relation.where("lower(data->>?) = ?", field, wanted[field])
            end
            matches = scope.limit(2).to_a
            matches.one? ? matches.first : nil
          end

          def census_match
            if identifiers.empty?
              errors.add(:base, I18n.t("decidim.elections.vocdoni.census_file_voter.not_ready"))
            elsif census_voter.blank?
              organization = translated_attribute(election.organization.name)
              errors.add(:base, I18n.t("decidim.elections.vocdoni.census_file_voter.invalid", organization:))
            end
          end
        end
      end
    end
  end
end
