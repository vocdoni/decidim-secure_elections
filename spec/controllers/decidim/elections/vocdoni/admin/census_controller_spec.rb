# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    module Admin
      describe CensusController do
        let(:organization) { create(:organization) }
        let(:user) { create(:user, :admin, :confirmed, organization:) }
        let(:participatory_space) { create(:participatory_process, organization:) }
        let(:component) { create(:vocdoni_component, participatory_space:) }
        # The census is step 3: it only opens once the details and the ballot
        # are complete, so the ballot has to be there for these screens to be
        # reachable at all.
        let(:election) { create(:vocdoni_election, :with_questions, component:, census_auth_fields: ["memberNumber"]) }

        let(:params) { { component_id: component.id, election_id: election.id } }

        before do
          request.env["decidim.current_organization"] = organization
          request.env["decidim.current_participatory_space"] = participatory_space
          request.env["decidim.current_component"] = component
          # A component engine is mounted once per participatory space type, so a
          # path generated from inside it needs to know which mount it belongs to.
          # A real request carries that as the engine's script name; a controller
          # spec never goes through the mount, so it has to be supplied here.
          request.env[Decidim::Elections::Vocdoni::AdminEngine.routes.env_key] =
            Decidim::EngineRouter.admin_proxy(component).root_path.chomp("/")
          sign_in user
        end

        describe "GET show" do
          before { get :show, params: }

          it { expect(response).to have_http_status(:ok) }
        end

        describe "GET members" do
          before { get :members, params: }

          # There is always a blank row, so the census can be started without
          # JavaScript.
          it "renders a row to type into" do
            expect(response).to have_http_status(:ok)
            expect(assigns(:form).members.size).to eq(1)
          end
        end

        describe "GET template" do
          it "emits a CSV with the columns this election needs" do
            get :template, params: params.merge(fields: %w(name memberNumber))

            expect(response.media_type).to eq("text/csv")
            expect(response.body.lines.first.strip).to eq("name,memberNumber")
          end

          it "falls back to the columns the election needs" do
            get(:template, params:)
            expect(response.body.lines.first).to include("memberNumber")
          end
        end

        describe "PATCH update" do
          let(:census_params) { { credentials: %w(memberNumber nationalId), two_factor_method: "email", weighted: "1" } }

          it "stores the authentication settings" do
            patch :update, params: params.merge(census: census_params)

            expect(election.reload.census_auth_fields).to match_array(%w(memberNumber nationalId))
            expect(election.census_two_fa_fields).to eq(["email"])
          end

          # The reason this class exists.
          it "refuses a census that identifies nobody" do
            patch :update, params: params.merge(census: { credentials: [], two_factor_method: "off" })

            expect(response).to have_http_status(:unprocessable_content)
            expect(election.reload.census_auth_fields).to eq(["memberNumber"])
          end
        end

        # The endpoint that reads a spreadsheet back. Every branch of it renders
        # something, and the one that reports failures is the one that used to
        # answer a full-page 500 — including for a file the product's own
        # template produced.
        describe "POST import" do
          let(:content) do
            <<~CSV
              name,surname,memberNumber
              Rosalind,Franklin,000123
              Grace,Hopper,000124
            CSV
          end

          let(:blob) do
            ActiveStorage::Blob.create_and_upload!(
              io: StringIO.new(content),
              filename: "census.csv",
              content_type: "text/csv"
            )
          end

          def import(file: blob.signed_id, replace: "0")
            post :import, params: params.merge(census_import: { file:, replace: })
          end

          it "adds the people and says how many" do
            import

            expect(response).to redirect_to(/census/)
            expect(flash[:notice]).to include("2 people")
            expect(election.census_members.count).to eq(2)
          end

          context "when only some rows can be read" do
            let(:content) do
              <<~CSV
                name,surname,memberNumber
                Rosalind,Franklin,000123
                Grace,Hopper,
              CSV
            end

            # Partial success is the normal case: the good rows go in and the
            # bad ones are named, with their line numbers, in the same response.
            it "imports what it can and reports the rest by row" do
              import

              expect(response).to redirect_to(/census/)
              expect(flash[:notice]).to include("1 person")
              expect(flash[:alert]).to include("Row 3")
              expect(flash[:alert]).to match(/member number/i)
              expect(election.census_members.count).to eq(1)
            end
          end

          context "when no row can be read" do
            let(:content) do
              <<~CSV
                name,surname,memberNumber
                Grace,Hopper,
              CSV
            end

            it "re-renders the census with the reason instead of a 500" do
              import

              expect(response).to have_http_status(:unprocessable_content)
              expect(response).to render_template(:show)
              expect(flash.now[:alert]).to include("Row 2")
              expect(election.census_members.count).to eq(0)
            end

            # `Decidim::Command` runs the callbacks with `instance_eval`, so a
            # form built inside one would be set on the command and never reach
            # the template. Building it up front is what makes `show`
            # renderable at all.
            it "still has the authentication form the template needs" do
              import

              expect(assigns(:form)).to be_a(Decidim::Elections::Vocdoni::Admin::CensusForm)
              expect(assigns(:form).credentials).to eq(["memberNumber"])
            end
          end

          # Downloading the template and uploading it straight back used to
          # enrol Ada Lovelace, status "Ready", with nothing to mark her out.
          # On a member-number-only census that is a credential printed in a
          # public download.
          describe "the template's example row" do
            let(:content) { Decidim::Elections::Vocdoni::CensusCsv::Template.new(%w(name surname memberNumber)).to_csv }

            it "is not imported, and the admin is told why nothing was" do
              import

              expect(response).to have_http_status(:unprocessable_content)
              expect(response).to render_template(:show)
              expect(flash.now[:alert]).to include("The example row that comes with the template was not imported")
              expect(election.census_members.count).to eq(0)
            end

            context "when the admin filled the template in around it" do
              let(:content) do
                <<~CSV
                  name,surname,memberNumber
                  Ada,Lovelace,000123
                  Grace,Hopper,000124
                CSV
              end

              it "imports the person and still says the example was left out" do
                import

                expect(flash[:notice]).to include("1 person was added")
                expect(flash[:notice]).to include("The example row that comes with the template was not imported")
                expect(election.census_members.pluck(:member_number)).to eq(["000124"])
              end
            end
          end

          context "when the file cannot be read at all" do
            let(:content) do
              <<~CSV
                colour,shape
                red,round
              CSV
            end

            it "says why the file was refused" do
              import

              expect(response).to have_http_status(:unprocessable_content)
              expect(flash.now[:alert]).to match(/no column this census recognises/i)
            end
          end

          context "when no file was chosen" do
            it "says so rather than failing" do
              import(file: "")

              expect(response).to have_http_status(:unprocessable_content)
              expect(response).to render_template(:show)
              expect(flash.now[:alert]).to be_present
            end
          end

          context "when replacing the census" do
            before { create(:vocdoni_census_member, election:, member_number: "999999") }

            it "empties it first" do
              import(replace: "1")

              expect(election.census_members.pluck(:member_number)).to match_array(%w(000123 000124))
            end

            # "2 people were added to the census" was the whole message, with
            # nothing at all about the person it had just deleted to make room.
            it "says what was removed as well as what was added" do
              import(replace: "1")

              expect(flash[:notice]).to include("1 person who was in the census was removed")
              expect(flash[:notice]).to include("2 people were added")
            end
          end

          context "when the file is not text" do
            let(:content) { "\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR".b }

            # The one that produced a full crash page: an unrescued
            # `ArgumentError: invalid byte sequence in UTF-8` out of the
            # separator sniffing, with no flash and no way back.
            it "re-renders the census with a reason instead of a 500" do
              expect { import }.not_to raise_error

              expect(response).to have_http_status(:unprocessable_content)
              expect(response).to render_template(:show)
              expect(flash.now[:alert]).to match(/could not be read as text/i)
              expect(election.census_members.count).to eq(0)
            end
          end

          context "when the file is a spreadsheet" do
            let(:blob) do
              ActiveStorage::Blob.create_and_upload!(
                io: StringIO.new("PK\x03\x04".b),
                filename: "census.xlsx",
                content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
              )
            end

            it "tells the admin to save it as CSV" do
              import

              expect(response).to have_http_status(:unprocessable_content)
              expect(flash.now[:alert]).to match(/is a spreadsheet/i)
            end
          end
        end

        # The other import on this screen, and the same trap: its `:invalid`
        # branch reads a form that only the controller has.
        describe "POST import_from_verifications" do
          it "re-renders the census saying which verification it refused" do
            post :import_from_verifications,
                 params: params.merge(census_verifications: { authorization_handler: "nonexistent", replace: "0" })

            expect(response).to have_http_status(:unprocessable_content)
            expect(response).to render_template(:show)
            expect(flash.now[:alert]).to be_present
            expect(assigns(:form)).to be_a(Decidim::Elections::Vocdoni::Admin::CensusForm)
          end
        end

        describe "DELETE clear" do
          before { create_list(:vocdoni_census_member, 2, election:) }

          it "empties the census" do
            delete(:clear, params:)
            expect(election.census_members.count).to eq(0)
          end
        end
      end
    end
  end
end
end
