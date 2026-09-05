# frozen_string_literal: true

require "spec_helper"

module Decidim
  module SecureElections
    module Admin
      describe ElectionsController do
        let(:organization) { create(:organization, available_locales: [:en]) }
        let(:participatory_space) { create(:participatory_process, organization:) }
        let(:component) { create(:vocdoni_component, participatory_space:) }
        let(:user) { create(:user, :admin, :confirmed, organization:) }

        let!(:election) { create(:vocdoni_election, :with_questions, component:, questions_count: 1, answers_count: 2) }

        let(:params) do
          { component_id: component.id }
        end

        # Step 1 asks for the details and nothing else.
        let(:details_params) do
          {
            title_en: "Updated election",
            description_en: "<p>Updated.</p>"
          }
        end

        before do
          request.env["decidim.current_organization"] = organization
          request.env["decidim.current_participatory_space"] = participatory_space
          request.env["decidim.current_component"] = component
          # A component engine is mounted once per participatory space type, so a
          # path generated from inside it needs to know which mount it belongs to.
          # A real request carries that as the engine's script name; a controller
          # spec never goes through the mount, so it has to be supplied here.
          request.env[Decidim::SecureElections::AdminEngine.routes.env_key] =
            Decidim::EngineRouter.admin_proxy(component).root_path.chomp("/")
          sign_in user
        end

        describe "GET new" do
          before { get :new, params: }

          it "asks only for the details" do
            expect(response).to have_http_status(:ok)
            expect(assigns(:form)).to be_a(Decidim::SecureElections::Admin::ElectionForm)
          end
        end

        describe "POST create" do
          it "creates the election from a title alone and moves on to the ballot" do
            post :create, params: params.merge(election: { title_en: "Brand new" })

            expect(Decidim::SecureElections::Election.last).to be_details_complete
            expect(response).to redirect_to(%r{questions/edit})
          end
        end

        describe "GET edit" do
          before { get :edit, params: params.merge(id: election.id) }

          it "renders the details step" do
            expect(response).to have_http_status(:ok)
            expect(assigns(:form)).to be_a(Decidim::SecureElections::Admin::ElectionForm)
          end
        end

        describe "GET show" do
          it "lands on the Dashboard tab" do
            get :show, params: params.merge(id: election.id)

            expect(response).to redirect_to(/dashboard/)
          end
        end

        describe "PATCH update" do
          it "saves the details and stays on the Main tab" do
            patch :update, params: params.merge(id: election.id, election: details_params)

            expect(translated(election.reload.title)).to eq("Updated election")
            expect(response).to redirect_to(%r{elections/#{election.id}/edit})
          end

          context "when the form is invalid" do
            it "stays on the details step" do
              patch :update, params: params.merge(id: election.id, election: details_params.merge(title_en: ""))

              expect(response).to have_http_status(:unprocessable_content)
            end
          end
        end

        # This is the reversible Decidim-visibility action, not the on-chain one.
        # It used to be called "Publish", which is also the name of wizard step
        # 5 — the irreversible publication guarded by a typed phrase — and the
        # flash said "Election published successfully", which reads as "it is
        # live" for an election that cannot take a single vote.
        describe "PUT publish" do
          it "says what it did, in the vocabulary of the public site" do
            put :publish, params: params.merge(id: election.id)

            expect(election.reload).to be_published
            expect(flash[:notice]).to include("shown on the public site")
            expect(flash[:notice]).not_to match(/published successfully/i)
          end

          it "does not let a page that cannot take a vote pass for a live election" do
            put :publish, params: params.merge(id: election.id)

            expect(flash[:notice]).to include("cannot take votes until you publish it on the blockchain")
          end

          context "when the election is already on chain" do
            let!(:election) { create(:vocdoni_election, :on_chain, component:, published_at: nil) }

            it "does not tell the admin to publish something that is already published" do
              put :publish, params: params.merge(id: election.id)

              expect(flash[:notice]).to include("shown on the public site")
              expect(flash[:notice]).not_to include("cannot take votes")
            end
          end
        end

        describe "PUT unpublish" do
          let!(:election) { create(:vocdoni_election, :published, :with_questions, component:) }

          it "is named symmetrically with the action that undoes it" do
            put :unpublish, params: params.merge(id: election.id)

            expect(election.reload).not_to be_published
            expect(flash[:notice]).to include("no longer shown on the public site")
          end
        end

        # PATCH autosave went away with Task 2's Main-tab rewrite: draft
        # autosave was dropped in favour of an explicit "Save and continue"
        # button on every save. The corresponding controller action and its
        # route are gone.
      end
    end
  end
end
