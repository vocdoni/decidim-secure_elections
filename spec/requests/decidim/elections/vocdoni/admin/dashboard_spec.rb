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

          it "does not show the CSP stats section or action buttons" do
            expect(card.at_css(".vocdoni-security-summary__csp-stats")).to be_nil
            expect(card.at_css(".vocdoni-security-summary__csp-actions")).to be_nil
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

        context "when the election has an external-CSP process (csp_elections present)" do
          let!(:election) do
            create(:election, :with_token_csv_census, :published, :ongoing, component:).tap do |record|
              q = create(:election_question, :with_response_options, election: record)
              proc = create(:vocdoni_process, :published, election: record)
              create(:vocdoni_csp_election, process: proc, decidim_question_id: q.id)
            end
          end

          it "shows the CSP stats section" do
            expect(card.at_css(".vocdoni-security-summary__csp-stats")).to be_present
          end

          it "shows the Sync census size button" do
            expect(card.text).to include(I18n.t("decidim.elections.vocdoni.admin.dashboard.security.sync_census_size.label"))
          end

          it "shows the Verify roots button when csp_state is nil" do
            process = election.vocdoni_process
            expect(process.csp_state).to be_nil

            expect(card.text).to include(I18n.t("decidim.elections.vocdoni.admin.dashboard.security.verify_roots.label"))
          end

          context "when csp_state is set" do
            before do
              election.vocdoni_process.update_column(:csp_state, "verified") # rubocop:disable Rails/SkipsModelValidations
              get dashboard_path, headers:
            end

            it "hides the Verify roots button once csp_state is set" do
              expect(card.text).not_to include(I18n.t("decidim.elections.vocdoni.admin.dashboard.security.verify_roots.label"))
            end

            it "still shows the Sync census size button" do
              expect(card.text).to include(I18n.t("decidim.elections.vocdoni.admin.dashboard.security.sync_census_size.label"))
            end
          end
        end

        context "when the Sync census size button is clicked" do
          let!(:election) do
            # ongoing: census_ready? is true so the :dashboard :election
            # permission passes for both published and running elections
            create(:election, :with_token_csv_census, :published, :ongoing, component:).tap do |record|
              q = create(:election_question, :with_response_options, election: record)
              proc = create(:vocdoni_process, :published, election: record)
              create(:vocdoni_csp_election, process: proc, decidim_question_id: q.id)
            end
          end
          let(:sync_path) do
            Decidim::EngineRouter.admin_proxy(component).sync_census_size_election_security_path(election)
          end

          it "is reachable from an ongoing election and enqueues ResizeCensusJob" do
            expect(ResizeCensusJob).to receive(:perform_later).with(election.vocdoni_process.id)

            post(sync_path, headers:)

            expect(response).to redirect_to(dashboard_path)
          end
        end

        context "when the Verify roots button is clicked" do
          let!(:election) do
            # ongoing: census_ready? is true so the :dashboard :election
            # permission passes for both published and running elections
            create(:election, :with_token_csv_census, :published, :ongoing, component:).tap do |record|
              q = create(:election_question, :with_response_options, election: record)
              proc = create(:vocdoni_process, :published, election: record)
              create(:vocdoni_csp_election, process: proc, decidim_question_id: q.id)
            end
          end
          let(:verify_path) do
            Decidim::EngineRouter.admin_proxy(component).verify_roots_election_security_path(election)
          end

          it "is reachable from an ongoing election and enqueues SyncProcessJob" do
            expect(SyncProcessJob).to receive(:perform_later).with(election.id)

            post(verify_path, headers:)

            expect(response).to redirect_to(dashboard_path)
          end
        end
      end
    end
  end
end
