# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      # `PerQuestionClientBooth` is prepended onto upstream's
      # `PerQuestionVotesController` (engine.rb `extend_upstream`).
      describe "PerQuestionClientBooth" do
        let(:organization) { component.organization }
        let(:component) { create(:elections_component) }
        let(:user) { create(:user, :confirmed, organization:) }
        let(:headers) { { "HOST" => organization.host } }
        let(:election) do
          create(:election, :published, :ongoing, :per_question, :with_internal_users_census, component:).tap do |el|
            create(:vocdoni_process, :published, election: el)
          end
        end
        let!(:open) { create(:election_question, :with_response_options, :voting_enabled, election:) }
        let!(:idle) { create(:election_question, :with_response_options, election:) }
        let(:router) { Decidim::EngineRouter.main_proxy(component) }

        before do
          allow_any_instance_of(Decidim::Elections::PerQuestionVotesController).to receive(:session_authenticated?).and_return(true) # rubocop:disable RSpec/AnyInstance
          allow(VotingBackend).to receive(:active_for?).and_return(true)
          login_as user, scope: :user
        end

        it "renders the client booth with only the open questions" do
          get(router.booth_election_per_question_votes_path(election_id: election.id), headers:)

          expect(response).to have_http_status(:ok)
          expect(response.body).to include("data-voting-booth")
          expect(response.body).to include(%(data-question-id="#{open.id}"))
          expect(response.body).not_to include(%(data-question-id="#{idle.id}"))
        end

        it "never renders the server-side question form" do
          get(router.election_per_question_vote_path(election_id: election.id, id: open.id), headers:)

          expect(response).to redirect_to(router.booth_election_per_question_votes_path(election_id: election.id))
        end

        it "sends a question that is not open back to the booth" do
          get(router.election_per_question_vote_path(election_id: election.id, id: idle.id), headers:)

          expect(response).to redirect_to(router.booth_election_per_question_votes_path(election_id: election.id))
        end

        it "never casts through Decidim" do
          expect(Decidim::Elections::CastVotes).not_to receive(:call)

          patch(router.election_per_question_vote_path(election_id: election.id, id: open.id),
                params: { response: { open.id.to_s => [open.response_options.first.id.to_s] } }, headers:)

          expect(response).to redirect_to(router.booth_election_per_question_votes_path(election_id: election.id))
        end

        it "lists the open questions in waiting.json" do
          get(router.waiting_election_per_question_votes_path(election_id: election.id, format: :json), headers:)

          expect(response.parsed_body["url"]).to end_with(router.booth_election_per_question_votes_path(election_id: election.id))
          expect(response.parsed_body["open_question_ids"]).to eq([open.id.to_s])
        end

        # The booth adds questions in place by fetching its own page again
        # (the fork's `booth_live.js`): that page must carry the new
        # question's section and its entry in the booth config.
        it "serves a question opened after the voter's first visit to the booth fetching itself again" do
          booth_path = router.booth_election_per_question_votes_path(election_id: election.id)
          get(booth_path, headers:)
          expect(response.body).not_to include(%(data-question-id="#{idle.id}"))

          idle.update!(voting_enabled_at: Time.current)
          open.update!(published_results_at: Time.current)
          get(booth_path, headers: headers.merge("Accept" => "text/html"))

          config = JSON.parse(response.parsed_body.at_css("[data-voting-booth]")["data-config"])
          expect(response.body).to include(%(data-question-id="#{idle.id}"))
          expect(response.body).not_to include(%(data-question-id="#{open.id}"))
          expect(config["questions"].pluck("questionId")).to eq([idle.id.to_s])
        end

        context "when no question is open" do
          let!(:open) { create(:election_question, :with_response_options, :voting_enabled, :published_results, election:) }

          it "sends the voter to the waiting room" do
            get(router.booth_election_per_question_votes_path(election_id: election.id), headers:)

            expect(response).to redirect_to(router.waiting_election_per_question_votes_path(election_id: election.id))
          end

          it "answers waiting.json with no url" do
            get(router.waiting_election_per_question_votes_path(election_id: election.id, format: :json), headers:)

            expect(response.parsed_body).to eq("url" => nil, "open_question_ids" => [])
          end
        end
      end
    end
  end
end
