# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    describe VotesController do
      let(:organization) { create(:organization) }
      let(:participatory_space) { create(:participatory_process, organization:) }
      let(:component) { create(:vocdoni_component, participatory_space:) }

      let(:election) { create(:vocdoni_election, :on_chain, component:) }
      let(:question) { election.questions.first }

      let(:params) do
        {
          component_id: component.id,
          election_id: election.id
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
        request.env[Decidim::Elections::Vocdoni::Engine.routes.env_key] =
          Decidim::EngineRouter.main_proxy(component).root_path.chomp("/")
      end

      # Voting is no longer a Rails page: it is a static file shipped inside
      # the gem and served by the engine's middleware. These three routes exist
      # only so that a bookmark, an email or a printed QR code minted before the
      # change still lands the voter on a ballot.
      describe "the old voting routes" do
        [:new, :show, :receipt].each do |action|
          it "redirects GET #{action} to the static voting page" do
            get(action, params:)

            expect(response).to have_http_status(:found)
            expect(response.location).to include(Decidim::Elections::Vocdoni::Engine::VOTE_PATH)
          end
        end

        # A 301 would be cached by the browser, and the target carries the
        # participant's locale — every later visit would be pinned to whichever
        # language they happened to use first.
        it "does not redirect permanently" do
          get(:new, params:)

          expect(response).not_to have_http_status(:moved_permanently)
        end
      end

      describe "the voting link" do
        subject(:query) { Rack::Utils.parse_query(URI.parse(response.location).query) }

        # What the one opaque parameter says, once unpacked. It is an
        # abbreviation and not a secret, which is exactly why a test can read it
        # back — see `Decidim::Elections::Vocdoni::VotingPageUrl`.
        let(:fields) do
          Decidim::Elections::Vocdoni::VotingPageUrl.decode(query["v"])
        end

        before { get :new, params: }

        it "points at the API and the process, and nothing else about the election" do
          expect(fields[:api]).to eq(Decidim::Elections::Vocdoni.api_url)
          expect(fields[:process]).to eq(election.vocdoni_process_id)
        end

        it "carries the participant's locale and a way back" do
          expect(fields[:locale]).to eq(I18n.locale.to_s)
          expect(fields[:exit]).to eq(controller.send(:exit_path))
        end

        # ARCHITECTURE §0.2. This is the assertion that matters most in this file:
        # the previous generation of this module shipped credentials to the
        # browser, and nothing about voting requires them.
        it "carries no credential of any kind" do
          expect(response.location).not_to include(Decidim::Elections::Vocdoni.api_key)
          expect(response.location).not_to include("vsk_")
          expect(query.keys).to eq(%w(v))
          expect(fields.keys).to contain_exactly(:api, :process, :locale, :exit)
        end

        # ARCHITECTURE §1: the browser signs against the question's `upstreamId`,
        # which it learns from `processes.check` per voter. Decidim never hands
        # it over.
        it "does not leak the upstream election ids" do
          expect(response.location).not_to include(question.vocdoni_upstream_id)
        end
      end

      context "when voting is closed" do
        let(:election) { create(:vocdoni_election, :on_chain, component:, status: "ended") }

        # A receipt outlives the vote: the nullifier is fetched back from the
        # CSP once the voter identifies themselves again, so the voting page
        # stays reachable after the election has closed.
        it "still sends the voter to the voting page" do
          get(:new, params:)

          expect(response.location).to include(Decidim::Elections::Vocdoni::Engine::VOTE_PATH)
        end
      end

      context "when the election is not on chain" do
        let(:election) { create(:vocdoni_election, :published, :ready_to_publish, component:) }

        it "sends the voter back to the election page, because there is no process to open" do
          get(:new, params:)

          expect(response).to redirect_to(controller.send(:exit_path))
          expect(flash[:alert]).to eq(I18n.t("decidim.elections.vocdoni.votes.errors.not_on_chain"))
        end
      end

      context "when the installation has no API URL configured" do
        before { allow(Decidim::Elections::Vocdoni).to receive(:api_url).and_return(nil) }

        it "refuses to mint a voting link that could only fail" do
          get(:new, params:)

          expect(response).to redirect_to(controller.send(:exit_path))
        end
      end
    end
  end
end
end
