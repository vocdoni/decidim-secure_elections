# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module AdminForms
        # The admin form of the "Participants from a file" census, as upstream's
        # Census tab sees it.
        #
        # The file itself is uploaded and mapped in our own wizard
        # ({Admin::CensusFileController}); upstream's "Save and continue" only
        # persists the census type. `ProcessCensus` overwrites
        # `election.census_settings` with whatever this form returns, so it
        # echoes back what the wizard and the Security tab stored.
        class CensusFileSettingsForm < Decidim::Form
          mimic :census_file_settings

          KEYS = %w(columns fields file identifiers).freeze

          attribute :election, Object

          def census_settings
            return {} if election.blank? || election.census_manifest_was.to_s != "token_csv"

            election.census_settings.to_h.slice(*KEYS)
          end

          # Upstream's Census tab builds this form with
          # `from_params(params, election:)`, which puts the election in the
          # form's *context*, never in its attributes. Read both: without the
          # context the election is nil here, this form echoes nothing, and
          # `ProcessCensus` wipes the columns, the mapping and the chosen
          # identifiers on every "Save and continue", leaving a census with
          # people in it that nobody can be identified by.
          def election
            super || (context[:election] if context)
          end
        end
      end
    end
  end
end
