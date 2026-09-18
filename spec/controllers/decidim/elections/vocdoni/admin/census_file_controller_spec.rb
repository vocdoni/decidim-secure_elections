# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Vocdoni
      module Admin
        describe CensusFileController do
          let(:component) { create(:elections_component) }
          let(:organization) { component.organization }
          let(:election) { create(:election, component:) }
          let(:current_user) { create(:user, :admin, :confirmed, organization:) }

          let(:content) do
            <<~CSV
              name,memberNumber
              Rosalind,000123
            CSV
          end

          let(:blob) do
            ActiveStorage::Blob.create_and_upload!(io: StringIO.new(content), filename: "people.csv", content_type: "text/csv")
          end

          before do
            request.env["decidim.current_organization"] = organization
            request.env["decidim.current_participatory_space"] = component.participatory_space
            request.env["decidim.current_component"] = component
            sign_in current_user
          end

          describe "POST create" do
            # The file goes to the Census tab, not to a page of its own: the
            # card there is where it is checked and imported. `manifest` rides
            # along so the card is the one on show, since choosing a file is
            # itself how the census type gets chosen.
            it "sends the admin back to the tab with the file to read" do
              post :create, params: { election_id: election.id, census_import: { file: blob.signed_id } }

              expect(response).to redirect_to(a_string_matching(%r{/census\?.*blob=}))
              expect(response.location).to include("manifest=token_csv")
            end

            it "takes a file posted straight from the drop zone, with no upload modal in between" do
              file = Rack::Test::UploadedFile.new(StringIO.new(content), "text/csv", original_filename: "people.csv")

              post :create, params: { election_id: election.id, census_import: { file: } }

              expect(response).to redirect_to(a_string_matching(%r{/census\?.*blob=}))
            end

            context "with no file" do
              # Nothing on the page is worth keeping: a file input cannot be
              # refilled from the server, so the card starts again with the
              # reason above it.
              it "returns to the tab and says why" do
                post :create, params: { election_id: election.id, census_import: {} }

                expect(response).to redirect_to(a_string_matching(%r{/census\z}))
                expect(flash[:alert]).to be_present
              end
            end
          end

          describe "PATCH update" do
            let(:columns) { { "0" => "name", "1" => "memberNumber" } }
            let(:identifiers) { %w(memberNumber) }

            it "imports the file and hands the admin back to the census tab" do
              patch :update, params: { election_id: election.id, census_file: { blob: blob.signed_id, columns:, identifiers: } }

              expect(election.voters.count).to eq(1)
              expect(response).to redirect_to(a_string_matching(%r{/census\z}))
            end

            context "when the file has a bad row" do
              let(:content) do
                <<~CSV
                  name,memberNumber,email
                  Rosalind,000123,not-an-email
                CSV
              end
              let(:columns) { { "0" => "name", "1" => "memberNumber", "2" => "email" } }

              it "renders the census tab again with the lines to fix, unprocessable" do
                patch :update, params: { election_id: election.id, census_file: { blob: blob.signed_id, columns:, identifiers: } }

                expect(response).to render_template("decidim/elections/admin/census/edit")
                expect(response).to have_http_status(:unprocessable_content)
                expect(election.voters.count).to eq(0)
              end
            end

            context "when the admin uploads the downloaded template untouched" do
              # The page itself is the fix here: it has to render, and say
              # what is wrong, so this one case goes through the views.
              render_views

              let(:content) do
                <<~CSV
                  First name,Member number
                  Ada,000123
                CSV
              end

              it "renders the census tab and says the file holds only the example line" do
                patch :update, params: { election_id: election.id, census_file: { blob: blob.signed_id, columns:, identifiers: } }

                expect(response).to render_template("decidim/elections/admin/census/edit")
                expect(response).to have_http_status(:unprocessable_content)
                expect(flash.now[:alert]).to eq(
                  I18n.t("census_file.update.only_example", scope: "decidim.elections.vocdoni.admin")
                )
                expect(response.body).to include(
                  I18n.t("decidim.elections.vocdoni.admin.census_file.review.nobody.title")
                )
                expect(response.body).not_to include(
                  I18n.t("decidim.elections.vocdoni.admin.census_file.review.submit", count: 0)
                )
                expect(election.voters.count).to eq(0)
              end
            end
          end

          describe "PATCH identifiers (update_identifiers)" do
            let(:election) do
              create(:election, component:, census_manifest: "token_csv",
                                census_settings: { "fields" => %w(name memberNumber) })
            end

            it "saves the chosen details and redirects to the census tab" do
              patch :update_identifiers, params: { election_id: election.id, census_identifiers: { identifiers: ["", "name"] } }

              expect(election.reload.census_settings["identifiers"]).to eq(%w(name))
              expect(response).to redirect_to(a_string_matching(%r{/census\z}))
            end

            it "falls back to what the columns imply when the form carries no answer at all" do
              patch :update_identifiers, params: { election_id: election.id, census_identifiers: { identifiers: [] } }

              expect(election.reload.census_settings["identifiers"]).to eq(%w(memberNumber))
              expect(response).to redirect_to(a_string_matching(%r{/census\z}))
            end

            # The boxes are preceded by an empty hidden field, so unticking
            # every one of them still reaches the server: that is what tells
            # "the admin cleared it" apart from "nobody has chosen yet", which
            # falls back to what the columns imply.
            context "when the admin unticks every detail" do
              it "renders the census tab again, unprocessable" do
                patch :update_identifiers, params: { election_id: election.id, census_identifiers: { identifiers: [""] } }

                expect(response).to render_template("decidim/elections/admin/census/edit")
                expect(response).to have_http_status(:unprocessable_content)
                expect(election.reload.census_settings["identifiers"]).to be_nil
              end
            end
          end

          describe "DELETE destroy" do
            before { Decidim::Elections::Voter.create!(election:, data: { "name" => "Ada" }) }

            it "removes the list and redirects to the census tab" do
              delete :destroy, params: { election_id: election.id }

              expect(election.voters.count).to eq(0)
              expect(response).to redirect_to(a_string_matching(%r{/census\z}))
            end
          end

          describe "GET template" do
            it "sends a CSV with the requested columns" do
              get :template, params: { election_id: election.id, fields: %w(name memberNumber) }

              expect(response.media_type).to eq("text/csv")
              body = response.body.force_encoding(Encoding::UTF_8)
              expect(body).to start_with("\uFEFF")
              expect(CSV.parse(body.delete_prefix("\uFEFF"), col_sep: ";").first).to eq(["First name", "Member number"])
            end

            it "falls back to a default set of columns when none are requested" do
              get :template, params: { election_id: election.id }

              expect(response).to be_successful
              expect(CSV.parse(response.body, col_sep: ";").first).not_to be_empty
            end
          end
        end
      end
    end
  end
end
