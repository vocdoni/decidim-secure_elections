# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Admin
      # Upstream's command, exercised with what this engine's Census tab
      # sends: the census type as `manifest` in the body, and the
      # registered-participants inputs under `internal_users`.
      #
      # The page itself is covered by the controller spec; this is where the
      # saving lives, and where the settings-wiping regression belongs.
      describe ProcessCensus do
        subject(:command) { described_class.new(form, election) }

        let(:organization) { create(:organization, available_authorizations: %w(dummy_authorization_handler)) }
        let(:component) { create(:elections_component, organization:) }
        let(:election) { create(:election, component:) }

        describe "registered participants" do
          let(:form) do
            Decidim::Elections::Admin::Censuses::InternalUsersForm
              .from_params({ internal_users: { authorization_handlers_names: %w(dummy_authorization_handler) } })
              .with_context(current_organization: organization, election:)
          end

          before { election.census_manifest = "internal_users" }

          it "saves the census type and the verifications that were ticked" do
            expect { command.call }.to broadcast(:ok)

            election.reload
            expect(election.census_manifest).to eq("internal_users")
            expect(election.census_settings["authorization_handlers"].keys).to eq(%w(dummy_authorization_handler))
          end
        end

        describe "a file census that is saved again" do
          # The regression this guards: saving the Census tab with the same
          # census still selected used to wipe the columns, the mapping and
          # the chosen identifiers the import stored, leaving a census with
          # people in it that nobody could be identified by.
          let(:stored_settings) do
            {
              "columns" => [{ "header" => "Name", "field" => "name" }],
              "fields" => %w(name),
              "identifiers" => %w(name),
              "file" => { "name" => "people.csv", "rows" => 1, "imported_at" => "2026-01-01T00:00:00Z" }
            }
          end
          let(:election) { create(:election, component:, census_manifest: "token_csv", census_settings: stored_settings) }
          let(:form) do
            Decidim::Elections::Vocdoni::AdminForms::CensusFileSettingsForm
              .from_params({}, election:)
          end

          it "keeps everything the import stored" do
            expect { command.call }.to broadcast(:ok)

            expect(election.reload.census_settings).to eq(stored_settings)
          end
        end
      end
    end
  end
end
