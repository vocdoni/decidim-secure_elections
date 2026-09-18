# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Admin
      # This is upstream's own controller. This engine takes it over with a
      # view override (`Decidim::Elections::Vocdoni::CensusPage`, prepended
      # in `phase_4_spike.rb`) rather than a controller of its own.
      #
      # Only the page itself is exercised here. What a save does is covered
      # by `spec/commands/decidim/elections/admin/process_census_spec.rb`:
      # upstream redirects to a route mounted once per participatory-space
      # type, which a controller spec cannot resolve, and the command is
      # where the behaviour actually lives.
      describe CensusController do
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
            get :edit, params: { id: election.id }

            expect(response).to be_successful
            expect(response.body).to include(I18n.t("legend", scope: "decidim.elections.vocdoni.admin.census_setup.choice"))
            expect(response.body).to include(I18n.t("legend", scope: "decidim.elections.vocdoni.admin.census_setup.registered"))
          end

          it "offers somewhere to drop a list, with no upload dialog in the way" do
            get :edit, params: { id: election.id }

            expect(response.body).to include(I18n.t("drop_zone.title", scope: "decidim.elections.vocdoni.admin.census_setup.file"))
            expect(response.body).to include("census_import[file]")
          end

          # An uploaded file comes back to this page rather than to one of its
          # own, so the card is where it is read, checked and imported.
          context "when a file has just been uploaded" do
            let(:blob) do
              ActiveStorage::Blob.create_and_upload!(
                io: StringIO.new("name,memberNumber\nRosalind,000123\n"),
                filename: "people.csv",
                content_type: "text/csv"
              )
            end

            it "reads it into the card, with what it understood and who it would let vote" do
              get :edit, params: { id: election.id, manifest: "token_csv", blob: blob.signed_id }

              expect(response).to be_successful
              expect(response.body).to include(
                I18n.t("decidim.elections.vocdoni.admin.census_file.review.people", count: 1)
              )
              expect(response.body).to include(
                I18n.t("decidim.elections.vocdoni.admin.census_file.review.submit", count: 1)
              )
              # Derived from the columns, not asked: a member number is unique
              # by definition, so it wins over the name beside it.
              expect(response.body).to include(
                Decidim::Elections::Vocdoni::CensusCsv::Fields.in_sentence("memberNumber")
              )
            end

            it "asks the admin to upload again when the link to the file has expired" do
              get :edit, params: { id: election.id, manifest: "token_csv", blob: "not-a-real-signed-id" }

              expect(response.body).to include(I18n.t("drop_zone.title", scope: "decidim.elections.vocdoni.admin.census_setup.file"))
            end
          end
        end
      end
    end
  end
end
