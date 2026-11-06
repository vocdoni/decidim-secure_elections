# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      # `RedirectsVoterToBooth` is included onto `Decidim::Elections::VotesController`
      # (see engine.rb `extend_upstream`). Its `before_action :render_vocdoni_booth_if_backed`
      # checks three conditions:
      #   1. The election has a Vocdoni sidecar (vocdoni_process.present?)
      #   2. The current action is not :receipt
      #   3. VotingBackend.active_for?(election) is false (rollback: static booth)
      #
      # When all three hold, it renders the standalone SPA template. When
      # VotingBackend.active_for? returns true (integrated booth), it steps aside.
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
          allow_any_instance_of(Decidim::Elections::VotesController).to receive(:session_authenticated?).and_return(false)
          login_as user, scope: :user
        end

        describe "for a Vocdoni-backed election (sidecar present)" do
          let(:election) do
            create(:election, :published, :ongoing, :with_internal_users_census, component:).tap do |el|
              create(:vocdoni_process, :published, election: el)
            end
          end

          context "when VOCDONI_INTEGRATED_BOOTH is disabled (static booth mode)" do
            # active_for? returns false → before_action renders the standalone SPA.
            before { allow(VotingBackend).to receive(:active_for?).and_return(false) }

            it "renders the standalone Vocdoni SPA booth template" do
              get new_vote_path, headers: headers
              expect(response).to have_http_status(:ok)
              # The SPA template is decidim/elections/vocdoni/booth/show.
              # It is rendered as an inline response body, not a redirect.
              expect(response.body).to include("vocdoni")
            end
          end

          context "when VOCDONI_INTEGRATED_BOOTH is enabled (integrated booth mode)" do
            # active_for? returns true → before_action steps aside, letting
            # UsesVotesBooth#new render the census form.
            before { allow(VotingBackend).to receive(:active_for?).and_return(true) }

            it "does not render the standalone SPA booth (passes through to upstream)" do
              get new_vote_path, headers: headers
              # Upstream renders its own new-vote template for an unauthenticated voter.
              expect(response).to have_http_status(:ok)
              expect(response.body).not_to match(%r{data-vocdoni-spa})
            end
          end
        end

        describe "for an election without a Vocdoni sidecar" do
          let(:election) do
            create(:election, :published, :ongoing, :with_internal_users_census, component:)
            # No vocdoni_process — vocdoni_process.blank? is true.
          end

          it "passes through to the upstream controller" do
            get new_vote_path, headers: headers
            # With no sidecar the before_action returns immediately.
            expect(response).to have_http_status(:ok)
          end
        end
      end
    end
  end
end
