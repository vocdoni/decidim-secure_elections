# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    describe ElectionsController do
      let(:organization) { create(:organization) }
      let(:participatory_space) { create(:participatory_process, organization:) }
      let(:component) { create(:vocdoni_component, participatory_space:) }

      let!(:election) { create(:vocdoni_election, :on_chain, component:, votes_count: 3) }
      let!(:unpublished_election) { create(:vocdoni_election, component:) }

      let(:params) do
        { component_id: component.id }
      end

      before do
        request.env["decidim.current_organization"] = organization
        request.env["decidim.current_participatory_space"] = participatory_space
        request.env["decidim.current_component"] = component
        # A component engine is mounted once per participatory space type, so a
        # path generated from inside it needs to know which mount it belongs to.
        # A real request carries that as the engine's script name; a controller
        # spec never goes through the mount, so it has to be supplied here.
        request.env[Decidim::Elections::Vocdoni::Engine.routes.env_key] =
          Decidim::EngineRouter.main_proxy(component).root_path.chomp("/")
      end

      describe "GET index" do
        # The collection is read lazily, by the view: `index` has no body and
        # `elections` is a helper method. Without rendering, nothing ever asks
        # for it and `@elections` stays nil.
        render_views

        before { get :index, params: }

        it "renders the list" do
          expect(response).to have_http_status(:ok)
        end

        it "only lists published elections" do
          expect(assigns(:elections)).to include(election)
          expect(assigns(:elections)).not_to include(unpublished_election)
        end
      end

      describe "GET show" do
        it "renders the election" do
          get :show, params: params.merge(id: election.id)

          expect(response).to have_http_status(:ok)
        end

        it "does not expose an unpublished election" do
          expect { get :show, params: params.merge(id: unpublished_election.id) }
            .to raise_error(ActiveRecord::RecordNotFound)
        end
      end

      describe "GET status" do
        let(:question) { election.questions.first }
        let(:answers) { question.answers.to_a }
        let(:payload) { response.parsed_body }
        let(:synced_at) { Time.current }

        # The shape `SyncResultsJob` writes: questions keyed by Decidim id,
        # answers keyed by Decidim id, finality under "final".
        let(:results_cache) do
          {
            "synced_at" => synced_at.iso8601,
            "votes_count" => 3,
            "questions" => {
              question.id.to_s => {
                "votes_count" => 3,
                "final" => false,
                "answers" => { answers.first.id.to_s => 2, answers.second.id.to_s => 1 }
              }
            }
          }
        end

        before do
          answers.first.update!(votes_count: 2)
          answers.second.update!(votes_count: 1)
          election.update!(votes_count: 3, results_cache:, results_synced_at: synced_at)

          get :status, params: params.merge(id: election.id, format: :json)
        end

        # ARCHITECTURE §0.5: polling this endpoint must never reach the SaaS API.
        # `webmock` would raise on a real request, so a green run is already the
        # assertion — but state it explicitly, because deferring the read is the
        # whole reason the cached columns exist.
        it "answers from the local cache without calling the API" do
          expect(response).to have_http_status(:ok)
          expect(WebMock).not_to have_requested(:any, /saas-api/)
        end

        it "does not schedule a refresh while the tally is fresh" do
          expect(Decidim::Elections::Vocdoni::SyncResultsJob).not_to have_been_enqueued
        end

        it "reports the cached tallies and their shares" do
          question_payload = payload["questions"].first

          expect(payload["votes_count"]).to eq(3)
          expect(question_payload["votes_count"]).to eq(3)
          expect(question_payload["answers"].map { |answer| answer["percent"] }).to eq([66.67, 33.33])
        end

        it "reports the lifecycle and the freshness of the tally" do
          expect(payload).to include("state" => "ongoing", "ongoing" => true, "stale" => false, "final" => false)
        end

        context "when the cached tally is stale" do
          let(:synced_at) { 10.minutes.ago }

          it "schedules a refresh instead of blocking the request on it" do
            expect(Decidim::Elections::Vocdoni::SyncResultsJob).to have_been_enqueued.with(election.id)
            expect(payload["stale"]).to be(true)
          end
        end
      end
    end
  end
end
end
