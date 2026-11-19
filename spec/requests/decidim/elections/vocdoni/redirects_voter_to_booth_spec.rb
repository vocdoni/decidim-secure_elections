# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      # `RedirectsVoterToBooth` renders a notice instead of upstream's wizard for
      # a Vocdoni election whose `vocdoni` voting backend is not active, and
      # steps aside when it is.
      describe "RedirectsVoterToBooth" do
        let(:organization) { component.organization }
        let(:component) { create(:elections_component) }
        let(:user) { create(:user, :confirmed, organization:) }
        let(:headers) { { "HOST" => organization.host } }
        let!(:question) { create(:election_question, :with_response_options, :voting_enabled, election:) }

        let(:new_vote_path) do
          Decidim::EngineRouter.main_proxy(component).new_election_vote_path(election_id: election.id)
        end

        before do
          # Bypass the census gate so we can reach the booth before_action.
          # We are testing RedirectsVoterToBooth, not the census; the gate is
          # covered by VotesController's own specs.
          #
          # Stub AuthorizedUsers so session_authenticated? sees an empty census
          # and returns false, without allow_any_instance_of on the controller.
          authorized_users_dbl = instance_double(Decidim::AuthorizedUsers, query: Decidim::User.none)
          allow(Decidim::AuthorizedUsers).to receive(:new).and_return(authorized_users_dbl)
          login_as user, scope: :user
        end

        describe "for a Vocdoni-backed election (sidecar present)" do
          let(:election) do
            create(:election, :published, :ongoing, :with_internal_users_census, component:).tap do |el|
              create(:vocdoni_process, :published, election: el)
            end
          end

          context "when the vocdoni voting backend is not active" do
            before { allow(VotingBackend).to receive(:active_for?).and_return(false) }

            it "renders the unavailable notice instead of upstream's wizard" do
              get(new_vote_path, headers:)
              expect(response).to have_http_status(:ok)
              expect(response.body).to include("data-vocdoni-booth-unavailable")
            end
          end

          context "when the vocdoni voting backend is active" do
            before { allow(VotingBackend).to receive(:active_for?).and_return(true) }

            it "passes through to upstream's booth" do
              get(new_vote_path, headers:)
              # Upstream renders its own new-vote template for an unauthenticated voter.
              expect(response).to have_http_status(:ok)
              expect(response.body).not_to include("data-vocdoni-booth-unavailable")
            end
          end
        end

        describe "for an election without a Vocdoni sidecar" do
          let(:election) do
            create(:election, :published, :ongoing, :with_internal_users_census, component:)
            # No vocdoni_process — vocdoni_process.blank? is true.
          end

          it "passes through to the upstream controller" do
            get(new_vote_path, headers:)
            # With no sidecar the before_action returns immediately.
            expect(response).to have_http_status(:ok)
          end
        end
      end
    end
  end
end
