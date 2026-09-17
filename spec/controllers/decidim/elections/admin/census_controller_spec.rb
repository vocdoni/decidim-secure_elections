# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Admin
      # This is upstream's own controller. This engine takes it over with a
      # view override (`Decidim::Elections::Vocdoni::CensusPage`, prepended
      # in `phase_4_spike.rb`) rather than a controller of its own, so the
      # engine has to be exercised through upstream's routes.
      describe CensusController do
        routes { Decidim::Elections::AdminEngine.routes }

        let(:organization) { create(:organization, available_authorizations: %w(dummy_authorization_handler)) }
        let(:component) { create(:elections_component, organization:) }
        let(:election) { create(:election, component:) }
        let(:current_user) { create(:user, :admin, :confirmed, organization:) }

        before do
          request.env["decidim.current_organization"] = organization
          request.env["decidim.current_participatory_space"] = component.participatory_space
          request.env["decidim.current_component"] = component
          sign_in current_user
        end

        describe "GET edit" do
          # This is the one thing worth going through the views for: proving
          # this engine's `app/views/decidim/elections/admin/census/edit.html.erb`
          # is the one that renders, not upstream's own file of the same name.
          # That is a matter of view-path load order, not of what the
          # controller returns, so only the rendered body can show it.
          render_views

          it "renders this engine's page rather than upstream's" do
            get :edit, params: { election_id: election.id }

            expect(response).to be_successful
            expect(response.body).to include(I18n.t("legend", scope: "decidim.elections.vocdoni.admin.census_setup.choice"))
            expect(response.body).to include(I18n.t("legend", scope: "decidim.elections.vocdoni.admin.census_setup.registered"))
          end
        end

        describe "PATCH update" do
          context "when Registered participants is chosen, with verifications ticked" do
            it "saves the census type and the chosen handlers" do
              patch :update, params: {
                election_id: election.id,
                manifest: "internal_users",
                internal_users: { authorization_handlers_names: %w(dummy_authorization_handler) }
              }

              election.reload
              expect(election.census_manifest).to eq("internal_users")
              expect(election.census_settings["authorization_handlers"].keys).to eq(%w(dummy_authorization_handler))
            end
          end

          context "when the election already is a file census with an imported list" do
            let(:stored_settings) do
              {
                "columns" => [{ "header" => "Name", "field" => "name" }],
                "fields" => %w(name),
                "identifiers" => %w(name),
                "file" => { "name" => "people.csv", "rows" => 1, "imported_at" => Time.current.iso8601 }
              }
            end
            let(:election) { create(:election, component:, census_manifest: "token_csv", census_settings: stored_settings) }

            # The regression this guards: saving the Census tab with the same
            # type still selected used to wipe the columns, the mapping and
            # the chosen identifiers the file wizard stored, leaving a census
            # with people in it that nobody could be identified by.
            it "keeps the census settings intact" do
              patch :update, params: { election_id: election.id, manifest: "token_csv" }

              election.reload
              expect(election.census_manifest).to eq("token_csv")
              expect(election.census_settings["columns"]).to eq(stored_settings["columns"])
              expect(election.census_settings["fields"]).to eq(stored_settings["fields"])
              expect(election.census_settings["identifiers"]).to eq(stored_settings["identifiers"])
              expect(election.census_settings["file"]["name"]).to eq("people.csv")
            end
          end

          context "when no census type is chosen and the election has none yet" do
            it "redirects with an alert instead of raising" do
              expect { patch :update, params: { election_id: election.id } }.not_to raise_error

              expect(response).to redirect_to(a_string_matching(%r{/census\z}))
              expect(flash[:alert]).to be_present
              expect(election.reload.census_manifest).to be_nil
            end
          end
        end
      end
    end
  end
end
