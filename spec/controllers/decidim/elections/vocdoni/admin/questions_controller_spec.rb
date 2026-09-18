# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    module Admin
      describe QuestionsController do
        let(:organization) { create(:organization, available_locales: [:en]) }
        let(:participatory_space) { create(:participatory_process, organization:) }
        let(:component) { create(:vocdoni_component, participatory_space:) }
        let(:user) { create(:user, :admin, :confirmed, organization:) }

        let!(:election) { create(:vocdoni_election, :with_questions, component:, questions_count: 1, answers_count: 2) }
        let(:question) { election.questions.first }
        let(:options) { question.answers.to_a }

        let(:params) do
          { component_id: component.id, election_id: election.id }
        end

        let(:ballot_params) do
          {
            question_type: "singlechoice",
            result_visibility: "live",
            questions: {
              "0" => {
                id: question.id,
                uid: "q0",
                body_en: "Do you agree?",
                description_en: "",
                answers: {
                  "0" => { id: options.first.id, uid: "q0-a0", body_en: "Yes" },
                  "1" => { id: options.second.id, uid: "q0-a1", body_en: "No" }
                }
              }
            }
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
          request.env[Decidim::Elections::Vocdoni::AdminEngine.routes.env_key] =
            Decidim::EngineRouter.admin_proxy(component).root_path.chomp("/")
          sign_in user
        end

        describe "GET edit" do
          it "renders the whole ballot on one page" do
            get(:edit, params:)
            expect(response).to have_http_status(:ok)
            expect(assigns(:form).questions.size).to eq(1)
            expect(assigns(:form).questions.first.answers.size).to eq(2)
          end

          context "when the election has no title yet" do
            let!(:election) { create(:vocdoni_election, component:, title: { en: "" }) }

            it "redirects to the details step and says why" do
              get(:edit, params:)
              expect(response).to redirect_to(%r{#{election.id}/edit})
              expect(flash[:alert]).to eq(I18n.t("decidim.elections.vocdoni.admin.nav.reasons.details_incomplete"))
            end
          end
        end

        describe "PATCH update" do
          it "saves the ballot and continues to the census" do
            patch :update, params: params.merge(election: ballot_params)

            expect(response).to redirect_to(/census/)
            expect(translated(question.reload.body)).to eq("Do you agree?")
          end

          context "when the form is invalid" do
            it "re-renders the step with something to edit" do
              patch :update, params: params.merge(election: ballot_params.merge(questions: {}))

              expect(response).to have_http_status(:unprocessable_content)
              expect(assigns(:form).questions).not_to be_empty
            end
          end
        end

        describe "PATCH autosave" do
          it "saves and answers with the ids the browser does not have yet" do
            ballot_params[:questions]["1"] = {
              uid: "q1",
              body_en: "A brand new question",
              description_en: "",
              answers: {
                "0" => { uid: "q1-a0", body_en: "Sure" },
                "1" => { uid: "q1-a1", body_en: "Never" }
              }
            }

            patch :autosave, params: params.merge(election: ballot_params), format: :json

            expect(response).to have_http_status(:ok)
            body = response.parsed_body
            expect(body["saved"]).to be(true)
            expect(body["questions"]["q0"]["id"]).to eq(question.id)
            expect(body["questions"]["q1"]["id"]).to be_present
            expect(body["questions"]["q1"]["answers"]["q1-a0"]).to be_present
          end

          it "reports a draft it could not save instead of redirecting" do
            patch :autosave, params: params.merge(election: ballot_params.merge(questions: {})), format: :json

            expect(response).to have_http_status(:unprocessable_content)
            expect(response.parsed_body["saved"]).to be(false)
          end
        end

        context "when the election is already on chain" do
          let!(:election) { create(:vocdoni_election, :on_chain, component:) }

          it "still shows the ballot, read-only" do
            get(:edit, params:)
            expect(response).to have_http_status(:ok)
          end

          it "refuses to save it" do
            patch :autosave, params: params.merge(election: ballot_params), format: :json

            expect(response).to have_http_status(:unprocessable_content)
          end
        end
      end
    end
  end
end
end
