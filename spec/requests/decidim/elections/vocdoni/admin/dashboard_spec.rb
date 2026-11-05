# frozen_string_literal: true

require "spec_helper"

# The "Your security configuration" card on upstream's Dashboard tab (AC3),
# rendered through the module's copy of upstream's dashboard view.
module Decidim
  module Elections
    module Vocdoni
      describe "Admin Dashboard security card" do
        let(:organization) { component.organization }
        let(:component) { create(:elections_component) }
        let(:admin) { create(:user, :admin, :confirmed, organization:) }
        let(:headers) { { "HOST" => organization.host } }
        let(:dashboard_path) { Decidim::EngineRouter.admin_proxy(component).dashboard_election_path(election) }
        let(:html) { response.parsed_body }
        let(:card) { html.at_css(".item__edit-form > .vocdoni-security-summary") }
        let(:sentences) { "decidim.elections.vocdoni.admin.security.show.summary.sentences" }

        before do
          login_as admin, scope: :user
          get dashboard_path, headers:
        end

        context "when the election is not published" do
          let!(:election) { create(:election, :with_token_csv_census, component:) }

          it "renders the card before the Main card" do
            expect(response).to have_http_status(:ok)
            expect(card).to be_present

            siblings = html.css(".item__edit-form > *")
            position = siblings.index(card)
            expect(siblings[position + 1]["class"]).to include("form__wrapper")
            expect(siblings[position + 1].text).to include(I18n.t("decidim.elections.admin.dashboard.main.title"))
          end

          it "titles the card and states the simple vote" do
            expect(card.at_css(".card-divider .card-title").text).to include("Your security configuration")
            expect(card.at_css("svg.vocdoni-security-summary__icon")).to be_present

            sentence = card.at_css(".vocdoni-security-summary__sentence")
            expect(sentence["data-security-level"]).to eq("basic")
            expect(sentence.text.strip).to eq(I18n.t("#{sentences}.basic"))
          end
        end

        context "when the election is published and opted in without a code" do
          let!(:election) do
            create(:election, :with_token_csv_census, :published, :ongoing, component:).tap do |record|
              create_list(:election_question, 2, :with_response_options, election: record)
              create(:vocdoni_process, election: record)
            end
          end

          it "renders the card after the Results card" do
            expect(response).to have_http_status(:ok)
            expect(html.css(".item__edit-form > *").last).to eq(card)
            expect(card.previous_element.text).to include(I18n.t("decidim.elections.admin.dashboard.results.title"))
          end

          it "states the secret vote" do
            sentence = card.at_css(".vocdoni-security-summary__sentence")

            expect(sentence["data-security-level"]).to eq("strong")
            expect(sentence.text.strip).to eq(I18n.t("#{sentences}.strong"))
          end
        end

        context "when the election is opted in with a one-time code" do
          let!(:election) do
            create(:election, :with_token_csv_census, component:).tap do |record|
              create(:vocdoni_process, :with_two_factor, election: record)
            end
          end

          it "states the secret vote with the code" do
            sentence = card.at_css(".vocdoni-security-summary__sentence")

            expect(sentence["data-security-level"]).to eq("strongest")
            expect(sentence.text.strip).to eq(I18n.t("#{sentences}.strongest"))
          end
        end
      end
    end
  end
end
