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

        context "when closing a question on chain failed" do
          let(:alert) { html.at_css(".item__edit-form > .vocdoni-question-failures") }
          let(:scope) { "decidim.elections.vocdoni.admin.dashboard.question_failures" }
          let!(:election) do
            create(:election, :with_token_csv_census, :per_question, :published, :ongoing, component:).tap do |record|
              closed = create(:election_question, :with_response_options, :voting_enabled, :published_results, election: record)
              create(:election_question, :with_response_options, election: record)
              create(:vocdoni_process, :published, election: record, metadata: {
                       "question_failures" => {
                         closed.id.to_s => { "message" => "invalid body", "step" => "question_publish_results",
                                             "attempts" => 35, "gave_up" => true }
                       }
                     })
            end
          end

          it "shows an alert above the security card naming the question and the error" do
            expect(response).to have_http_status(:ok)
            expect(alert).to be_present
            expect(alert["role"]).to eq("alert")
            expect(alert.next_element).to eq(card)

            text = alert.text.squish
            expect(text).to include(I18n.t("#{scope}.title"))
            expect(text).to include(I18n.t("#{scope}.question_publish_results"))
            expect(text).to include(I18n.t("#{scope}.gave_up"))
            expect(text).to include("invalid body")
            expect(alert.css("li").size).to eq(1)
          end
        end

        context "when no question failed on chain" do
          let!(:election) { create(:election, :with_token_csv_census, component:) }

          it "shows no alert" do
            expect(html.at_css(".vocdoni-question-failures")).to be_nil
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

      # The "Census for the secret vote" card: the admin sees how many voters the census has and
      # the maximum the election declares when voting starts.
      describe "Admin Dashboard census snapshot card" do
        let(:organization) { component.organization }
        let(:component) { create(:elections_component) }
        let(:admin) { create(:user, :admin, :confirmed, organization:) }
        let(:headers) { { "HOST" => organization.host } }
        let(:dashboard_path) { Decidim::EngineRouter.admin_proxy(component).dashboard_election_path(election) }
        let(:html) { response.parsed_body }
        let(:snapshot) { html.at_css(".item__edit-form > .vocdoni-census-snapshot") }
        let(:scope) { "decidim.elections.vocdoni.admin.dashboard.census_snapshot" }

        before do
          login_as admin, scope: :user
          get dashboard_path, headers:
        end

        context "when the election opted in and has voters" do
          let!(:election) do
            create(:election, :with_token_csv_census, component:).tap do |record|
              create(:vocdoni_process, election: record)
            end
          end

          it "renders after the Census card with the count, the late joiners note and the projected maximum" do
            expect(response).to have_http_status(:ok)
            expect(snapshot["data-census-count"]).to eq("3")
            expect(snapshot.previous_element.text).to include(I18n.t("decidim.elections.admin.dashboard.census.title"))
            expect(snapshot.at_css("[data-census-maximum]")["data-census-maximum"]).to eq("4")

            text = snapshot.text.squish
            expect(text).to include(I18n.t("#{scope}.count", count: 3))
            expect(text).to include(I18n.t("#{scope}.late_joiners"))
            expect(text).to include(I18n.t("#{scope}.projected", count: 4))
            expect(snapshot.at_css(".callout.alert")).to be_nil
          end
        end

        context "when the election opted in with an empty registered participants census" do
          let!(:election) do
            create(:election, component:, census_manifest: "internal_users",
                              census_settings: { "authorization_handlers" => { "csv_census" => { "options" => {} } } }).tap do |record|
              create(:vocdoni_process, election: record)
            end
          end

          it "warns that the secret vote cannot start" do
            expect(snapshot["data-census-count"]).to eq("0")
            expect(snapshot.at_css(".callout.alert").text.squish).to eq(I18n.t("#{scope}.empty"))
          end
        end

        context "when the election is published but voting has not started" do
          let!(:election) do
            create(:election, :with_token_csv_census, :published, :scheduled, component:).tap do |record|
              create_list(:election_question, 1, :with_response_options, election: record)
              create(:vocdoni_process, election: record)
            end
          end

          it "renders after the security card" do
            expect(response).to have_http_status(:ok)
            expect(snapshot["data-census-count"]).to eq("3")
            expect(snapshot.previous_element["class"]).to include("vocdoni-security-summary")
          end
        end

        context "when the SaaS process exists but is not published" do
          let!(:election) do
            create(:election, :with_token_csv_census, component:).tap do |record|
              create(:vocdoni_process, election: record, state: "failed",
                                       vocdoni_process_id: "6885f0c2c1a4e2f0b1d33a01", census_size: 12)
            end
          end

          it "gives the declared maximum" do
            expect(snapshot.at_css("[data-census-maximum]")["data-census-maximum"]).to eq("12")
            expect(snapshot.text.squish).to include(I18n.t("#{scope}.declared", count: 12))
          end
        end

        context "when voting has started" do
          let!(:election) do
            create(:election, :with_token_csv_census, :published, :ongoing, component:).tap do |record|
              create_list(:election_question, 1, :with_response_options, election: record)
              create(:vocdoni_process, election: record)
            end
          end

          it "does not render the card" do
            expect(response).to have_http_status(:ok)
            expect(snapshot).to be_nil
          end
        end

        context "when the election did not opt in" do
          let!(:election) { create(:election, :with_token_csv_census, component:) }

          it "does not render the card" do
            expect(response).to have_http_status(:ok)
            expect(snapshot).to be_nil
          end
        end
      end
    end
  end
end
