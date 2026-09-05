# frozen_string_literal: true

require "spec_helper"

# The Dashboard tab: a single page that branches on the election's on-chain
# state. Pre-publish it is a completeness checklist + sticky publish form;
# post-publish it becomes the live-refresh monitor view.
#
# Five sub-cases drive the two halves:
#   1. all checks passing → publish button present
#   2. one check failing → error icon + fix-it link
#   3. tick checkbox and submit → PublishElectionJob enqueued
#   4. manual-start + paused → "Start election" button present
#   5. on-chain + ongoing → #js-vocdoni-monitor present
describe "Admin Dashboard tab" do
  include_context "when managing a component as an admin"

  let(:manifest_name) { "vocdoni" }
  let(:election_path) { Decidim::EngineRouter.admin_proxy(component) }

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  def visit_dashboard(election)
    visit election_path.election_dashboard_path(election)
  end

  # =====================================================================
  # Unpublished half
  # =====================================================================

  describe "unpublished election" do
    context "when all completeness checks pass" do
      let!(:election) do
        create(:vocdoni_election, :ready_to_publish, component:, skip_injection: true)
      end

      before { visit_dashboard(election) }

      # Sub-case 1: checklist + publish form visible and operational.
      it "shows the publish setup form" do
        expect(page).to have_css("#js-vocdoni-setup")
      end

      it "shows the 'Publish on the blockchain' button" do
        # setup.js disables the button until the confirm_irreversible
        # checkbox is ticked; either state is a legitimate render of the
        # button so accept both.
        expect(page).to have_button(
          I18n.t("decidim.secure_elections.admin.setup.show.publish_button"),
          disabled: :all
        )
      end

      it "shows the confirm-irreversible checkbox" do
        expect(page).to have_field(
          I18n.t("decidim.secure_elections.admin.setup.show.confirm_irreversible_label")
        )
      end

      it "renders a checklist with all items marked done" do
        # All five check icons should be check-line (ok), none error-warning-line.
        within ".card", text: I18n.t("decidim.secure_elections.admin.setup.show.checklist_title") do
          expect(page).to have_no_css("svg use[href*='error-warning-line']")
        end
      end
    end

    # Sub-case 2: one check failing.
    context "when the questions check fails (no questions)" do
      let!(:election) do
        # A census is present but no questions → questions_complete? is false.
        create(:vocdoni_election, :with_census, component:, skip_injection: true)
      end

      before { visit_dashboard(election) }

      it "shows an error icon on the questions row" do
        within ".card", text: I18n.t("decidim.secure_elections.admin.setup.show.checklist_title") do
          questions_label = I18n.t("questions", scope: "decidim.secure_elections.admin.setup.checks")
          item = find("li", text: questions_label)
          expect(item).to have_css("svg use[href*='error-warning-line']")
        end
      end

      it "shows a fix-it link pointing to the questions editor" do
        within ".card", text: I18n.t("decidim.secure_elections.admin.setup.show.checklist_title") do
          questions_label = I18n.t("questions", scope: "decidim.secure_elections.admin.setup.checks")
          item = find("li", text: questions_label)
          expect(item).to have_link(
            I18n.t("decidim.secure_elections.admin.setup.show.fix_it"),
            href: election_path.edit_election_questions_path(election)
          )
        end
      end

      it "renders the publish button as disabled" do
        # When checks fail, `ready` is false → the disabled branch is rendered.
        expect(page).to have_button(
          I18n.t("decidim.secure_elections.admin.setup.show.publish_button"),
          disabled: true
        )
      end
    end

    # Sub-case 3: tick checkbox and submit → job enqueued.
    context "when the admin confirms and submits the setup form" do
      let!(:election) do
        create(:vocdoni_election, :ready_to_publish, component:, skip_injection: true)
      end

      it "enqueues PublishElectionJob" do
        allow(Decidim::SecureElections::PublishElectionJob)
          .to receive(:perform_later)
          .and_call_original

        visit_dashboard(election)

        # Tick the irreversible checkbox.
        check I18n.t("decidim.secure_elections.admin.setup.show.confirm_irreversible_label")

        # Submit the form via the hidden field name (the JS-gated button may be
        # "enabled" in tests without a JS driver — we fire the submit directly).
        within "#js-vocdoni-setup" do
          find("form").native.submit
        end

        expect(Decidim::SecureElections::PublishElectionJob)
          .to have_received(:perform_later)
          .with(election.id)
      end
    end
  end

  # =====================================================================
  # Published / on-chain half
  # =====================================================================

  describe "on-chain election" do
    # Sub-case 4: manual start + paused → "Start election" visible.
    context "when the election is manual-start and currently paused" do
      let!(:election) do
        create(
          :vocdoni_election,
          :on_chain,
          component:,
          skip_injection: true,
          manual_start: true,
          status: "paused"
        )
      end

      before { visit_dashboard(election) }

      it "shows the 'Start election' button" do
        expect(page).to have_button(
          I18n.t("decidim.secure_elections.admin.dashboard.start.button")
        )
      end
    end

    # Sub-case 5: ongoing election → monitor markup present.
    context "when the election is ongoing" do
      let!(:election) do
        create(
          :vocdoni_election,
          :on_chain,
          component:,
          skip_injection: true,
          status: "ready"
        )
      end

      before { visit_dashboard(election) }

      it "renders the live-refresh monitor container" do
        expect(page).to have_css("#js-vocdoni-monitor")
      end

      it "sets data-status-url to the dashboard JSON path" do
        monitor = find_by_id("js-vocdoni-monitor")
        expected = election_path.election_dashboard_path(election, format: :json)
        expect(monitor["data-status-url"]).to eq(expected)
      end

      it "renders the results section" do
        expect(page).to have_css("#js-vocdoni-monitor-results")
      end
    end
  end
end
