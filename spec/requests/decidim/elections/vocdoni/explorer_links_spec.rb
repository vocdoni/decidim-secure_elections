# frozen_string_literal: true

require "spec_helper"

# Explorer links on the public election page (a "Vocdoni explorer" tab) and on
# the admin Dashboard (a card after the security one): one per question.
module Decidim
  module Elections
    module Vocdoni
      describe "Explorer links" do
        let(:organization) { component.organization }
        let(:component) { create(:elections_component, :published) }
        let(:headers) { { "HOST" => organization.host } }
        let(:html) { response.parsed_body }
        let(:election) { create(:election, :published, :ongoing, :with_internal_users_census, component:) }
        let!(:first_question) { create(:election_question, :with_response_options, election:) }
        let!(:second_question) { create(:election_question, :with_response_options, election:) }
        let(:urls) { %w(https://stg.explorer.vote/process/aa01 https://stg.explorer.vote/process/bb02) }
        let(:process_state) { :published }

        before do
          allow(Vocdoni).to receive(:explorer_url).and_return("https://stg.explorer.vote")
          create(:vocdoni_process, process_state, election:, metadata: {
                   "questions" => [
                     { "decidim_question_id" => first_question.id, "vocdoni_upstream_id" => "aa01" },
                     { "decidim_question_id" => second_question.id, "vocdoni_upstream_id" => "bb02" }
                   ]
                 })
        end

        describe "public election page" do
          let(:panel) { html.at_css("#panel-vocdoni-explorer") }

          before { get Decidim::EngineRouter.main_proxy(component).election_path(election), headers: }

          it "adds a tab with one link per question" do
            expect(response).to have_http_status(:ok)
            expect(html.at_css("#trigger-vocdoni-explorer").text).to include("Vocdoni explorer")
            expect(panel.css("a").map { |a| a["href"] }).to eq(urls)
            expect(panel.css(".card__list-title").map { |title| title.text.strip })
              .to eq([first_question, second_question].map { |question| translated(question.body) })
          end

          context "when the election is not on chain yet" do
            let(:process_state) { :publishing }

            it "has no explorer tab" do
              expect(response).to have_http_status(:ok)
              expect(html.at_css("#trigger-vocdoni-explorer")).to be_nil
              expect(panel).to be_nil
            end
          end
        end

        describe "admin dashboard" do
          let(:admin) { create(:user, :admin, :confirmed, organization:) }
          let(:card) { html.at_css(".item__edit-form > .vocdoni-explorer-links") }

          before do
            login_as admin, scope: :user
            get Decidim::EngineRouter.admin_proxy(component).dashboard_election_path(election), headers:
          end

          it "renders a card after the security card with one link per question" do
            expect(response).to have_http_status(:ok)
            expect(card.previous_element["class"]).to include("vocdoni-security-summary")
            expect(card.css("a").map { |a| a["href"] }).to eq(urls)
            expect(card.text).to include("View on the explorer")
          end

          context "when the election is not on chain yet" do
            let(:process_state) { :publishing }

            it "renders no card" do
              expect(response).to have_http_status(:ok)
              expect(card).to be_nil
            end
          end
        end
      end
    end
  end
end
