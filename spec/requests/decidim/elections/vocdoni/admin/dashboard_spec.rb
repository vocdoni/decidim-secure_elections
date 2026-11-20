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
            expect(html.at_css(".vocdoni-pending-actions")).to be_nil
          end
        end

        context "when admin changes wait for a busy organization" do
          let(:notice) { html.at_css(".item__edit-form > .vocdoni-pending-actions") }
          let(:scope) { "decidim.elections.vocdoni.admin.dashboard.pending_actions" }
          let(:since) { Time.zone.parse("2026-11-20T10:05:00Z") }
          let(:question) { election.questions.first }
          let!(:election) do
            create(:election, :with_token_csv_census, :per_question, :published, :ongoing, component:).tap do |record|
              question = create(:election_question, :with_response_options, :voting_enabled, election: record)
              create(:vocdoni_process, :published, election: record, metadata: {
                       "pending_actions" => {
                         "end" => { "since" => since.iso8601, "attempts" => 3, "at" => since.iso8601 },
                         "question_#{question.id}_enable_voting" => { "since" => since.iso8601, "attempts" => 61,
                                                                      "at" => since.iso8601, "gave_up" => true }
                       }
                     })
            end
          end

          it "shows each waiting change with its progress" do
            expect(response).to have_http_status(:ok)
            expect(notice).to be_present
            expect(notice.text.squish).to include(I18n.t("#{scope}.title"))

            waiting = notice.at_css("[data-pending-action='end']").text.squish
            expect(waiting).to include(I18n.t("#{scope}.actions.end"))
            expect(waiting).to include(I18n.t("#{scope}.waiting", since: I18n.l(since, format: "%H:%M"), count: 3))

            gave_up = notice.at_css("[data-pending-action='question_#{question.id}_enable_voting']").text.squish
            expect(gave_up).to include(I18n.t("#{scope}.gave_up"))
            expect(gave_up).not_to include(I18n.t("#{scope}.gave_up_publish"))
          end
        end

        context "when a pending entry has no usable start time" do
          let!(:election) do
            create(:election, :with_token_csv_census, :published, :ongoing, component:).tap do |record|
              create(:vocdoni_process, :published, election: record, metadata: {
                       "pending_actions" => { "end" => { "since" => "garbage", "attempts" => 2, "at" => "" } }
                     })
            end
          end

          it "still renders the dashboard" do
            expect(response).to have_http_status(:ok)
            expect(html.at_css("[data-pending-action='end']").text).to include("--:--")
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

      # The "Census for the secret vote" card: publishing registers the census
      # as it is, so the admin sees how many voters that is beforehand.
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

          it "renders after the Census card with the count and the late joiners note" do
            expect(response).to have_http_status(:ok)
            expect(snapshot["data-census-count"]).to eq("3")
            expect(snapshot.previous_element.text).to include(I18n.t("decidim.elections.admin.dashboard.census.title"))

            text = snapshot.text.squish
            expect(text).to include(I18n.t("#{scope}.count", count: 3))
            expect(text).to include(I18n.t("#{scope}.late_joiners"))
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

          it "warns that the secret vote cannot start and asks for verifications first" do
            expect(snapshot["data-census-count"]).to eq("0")
            expect(snapshot.at_css(".callout.alert").text.squish).to eq(I18n.t("#{scope}.empty"))

            text = snapshot.text.squish
            expect(text).to include(I18n.t("#{scope}.limitations"))
            expect(text).to include(I18n.t("#{scope}.verify_before_start"))
          end
        end

        context "when the election is published but voting has not started" do
          let!(:election) do
            create(:election, :with_token_csv_census, :published, :scheduled, component:).tap do |record|
              create_list(:election_question, 1, :with_response_options, election: record)
              create(:vocdoni_process, election: record)
            end
          end

          it "renders after the security card, without the verifications item for a CSV census" do
            expect(response).to have_http_status(:ok)
            expect(snapshot["data-census-count"]).to eq("3")
            expect(snapshot.previous_element["class"]).to include("vocdoni-security-summary")
            expect(snapshot.text.squish).not_to include(I18n.t("#{scope}.verify_before_start"))
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

      describe "publish failure alert" do
        let(:organization) { component.organization }
        let(:component) { create(:elections_component) }
        let(:admin) { create(:user, :admin, :confirmed, organization:) }
        let(:headers) { { "HOST" => organization.host } }
        let(:dashboard_path) { Decidim::EngineRouter.admin_proxy(component).dashboard_election_path(election) }
        let(:html) { response.parsed_body }
        let(:failure_alert) { html.at_css(".vocdoni-publish-failure") }
        let(:platform_url) { nil }
        let(:scope) { "decidim.elections.vocdoni.admin.dashboard.publish_failure" }

        before do
          Decidim::Elections::Vocdoni.platform_url = platform_url
          login_as admin, scope: :user
          get dashboard_path, headers:
        end

        after { Decidim::Elections::Vocdoni.platform_url = nil }

        context "when the vocdoni process failed" do
          let!(:election) do
            create(:election, :with_token_csv_census, component:).tap do |record|
              create(:vocdoni_process, :failed, election: record)
            end
          end

          it "renders a failure alert with the error message" do
            expect(response).to have_http_status(:ok)
            expect(failure_alert).to be_present
            expect(failure_alert.text).to include("census size exceeds email allowance")
          end

          it "offers to retry the publication" do
            retry_path = Decidim::EngineRouter.admin_proxy(component).election_publish_retry_path(election)
            expect(failure_alert.at_css("form[action='#{retry_path}'] button").text).to include("Retry publication")
          end
        end

        context "when the publish was refused for lack of credit" do
          let!(:election) do
            create(:election, :with_token_csv_census, component:).tap do |record|
              create(:vocdoni_process, :failed,
                     election: record,
                     last_error: "insufficient integrator wallet balance",
                     metadata: { "last_error" => { "code" => 40_175, "data" => { "requiredCents" => 10_341, "availableCents" => 0 } } })
            end
          end

          let(:action) { failure_alert.at_css(".vocdoni-publish-failure__billing-action") }

          it "explains the billing problem with the amount instead of the raw error" do
            expect(failure_alert.at_css(".vocdoni-publish-failure__billing").text).to include("no credit left", "103.41")
            expect(failure_alert.text).not_to include("insufficient integrator wallet balance")
            expect(failure_alert.text).not_to include("support")
          end

          context "with a known Vocdoni platform" do
            let(:platform_url) { "https://platform.vocdoni.io" }

            it "sends the organization admin to top up the wallet there" do
              link = action.at_css("a[href='https://platform.vocdoni.io']")
              expect(link.text).to eq(I18n.t("#{scope}.billing_platform"))
              expect(link["target"]).to eq("_blank")
            end
          end

          context "without a known Vocdoni platform" do
            it "asks the organization admin to top up the wallet" do
              expect(action.text.squish).to eq(I18n.t("#{scope}.billing_top_up"))
              expect(action.at_css("a")).to be_nil
            end
          end

          context "when the viewer administers only the space" do
            let(:platform_url) { "https://platform.vocdoni.io" }
            let(:admin) { create(:process_admin, :confirmed, participatory_process: component.participatory_space) }

            it "sends them to their organization admin, without the platform link" do
              expect(response).to have_http_status(:ok)
              expect(action.text.squish).to eq(I18n.t("#{scope}.billing_ask_admin"))
              expect(action.at_css("a")).to be_nil
            end
          end
        end

        context "when the vocdoni process is pending" do
          let!(:election) do
            create(:election, :with_token_csv_census, component:).tap do |record|
              create(:vocdoni_process, election: record)
            end
          end

          it "does not render a failure alert" do
            expect(response).to have_http_status(:ok)
            expect(failure_alert).to be_nil
          end
        end
      end
    end
  end
end
