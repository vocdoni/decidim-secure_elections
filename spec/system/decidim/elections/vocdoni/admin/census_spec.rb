# frozen_string_literal: true

require "spec_helper"

# The Census tab: manifest selector + inline auth-config form + 5-row preview.
#
# Adopts upstream decidim-elections' shape: a manifest <select> at the top
# switches between per-manifest inline form partials; the current vd flow
# ("internal users" — configure credentials and 2FA, manage members directly)
# becomes the `internal_users` partial.
#
# DOM contract (per task brief §4):
#   #census-manifest-selector  — <select> with at least "internal_users" option
#   #census-election-form      — the inline auth-config form
#   .card-section.census-form  — wrapper around form + preview
#   .item__edit-sticky         — sticky Save button linked to #census-election-form
describe "Admin Census tab" do
  include_context "when managing a component as an admin"

  let(:manifest_name) { "vocdoni" }
  let(:election_path) { Decidim::EngineRouter.admin_proxy(component) }

  # Census tab requires questions to be complete (wizard_step guard).
  let!(:election) { create(:vocdoni_election, :with_questions, component:, skip_injection: true) }

  before do
    visit election_path.election_census_path(election)
  end

  # ── Manifest selector ─────────────────────────────────────────────────────

  it "renders the manifest selector with the correct id" do
    expect(page).to have_css("#census-manifest-selector")
  end

  it "includes the internal_users option in the manifest selector" do
    within "#census-manifest-selector" do
      expect(page).to have_css("option", text: /internal users/i)
    end
  end

  # ── Inline form ───────────────────────────────────────────────────────────

  it "renders the census form with the required id" do
    expect(page).to have_css("#census-election-form")
  end

  it "wraps the form in the census-form card-section" do
    expect(page).to have_css(".card-section.census-form #census-election-form")
  end

  it "shows the credentials section inside the form" do
    within "#census-election-form" do
      expect(page).to have_css("#js-census-authentication")
    end
  end

  # ── Sticky Save ───────────────────────────────────────────────────────────

  it "renders the sticky Save button linked to the census form" do
    # The button has Foundation's `.hide` (display: none) when the census
    # is not yet configured; Capybara's default is `visible: :visible`,
    # which filters that out. Assert on the DOM regardless of visibility.
    expect(page).to have_css(".item__edit-sticky button[form='census-election-form']", visible: :all)
  end

  it "hides the Save button when authentication is not yet configured" do
    # New election with no census auth fields → button has the 'hide' class
    expect(page).to have_css(".item__edit-sticky button.hide[form='census-election-form']", visible: :all)
  end

  context "when census authentication is configured" do
    let!(:election) do
      create(:vocdoni_election, :with_questions, :with_census, component:, skip_injection: true)
    end

    before do
      visit election_path.election_census_path(election)
    end

    it "shows the Save button without the hide class" do
      expect(page).to have_no_css(".item__edit-sticky button.hide[form='census-election-form']", visible: :all)
      expect(page).to have_css(".item__edit-sticky button[form='census-election-form']")
    end
  end

  # ── Preview partial ───────────────────────────────────────────────────────

  context "when there are no census members" do
    it "does not render the preview table" do
      # Preview only renders when preview_users is present
      within ".card-section.census-form" do
        expect(page).to have_no_css(".table-list")
      end
    end
  end

  context "when the census has members" do
    let!(:election) do
      create(:vocdoni_election, :with_questions, :with_census,
             census_members_count: 3, component:, skip_injection: true)
    end

    before do
      visit election_path.election_census_path(election)
    end

    it "shows the preview table inside the census-form section" do
      within ".card-section.census-form" do
        expect(page).to have_css(".table-list")
      end
    end

    it "shows at most five rows in the preview" do
      within ".card-section.census-form .table-list tbody" do
        expect(all("tr").length).to be <= 5
      end
    end

    it "shows the census size line below the preview table" do
      within ".card-section.census-form" do
        expect(page).to have_text(/people in the census/i)
      end
    end
  end

  # ── Census complete announcement ─────────────────────────────────────────

  # The success callout renders only when Election#census_complete? holds,
  # which needs the census to be configured AND populated. The `:with_census`
  # trait only configures auth fields; the members table is populated by a
  # separate seed step that would make this test brittle without adding
  # much coverage. The `census_complete?` predicate itself is unit-tested.

  # ── Tab strip ─────────────────────────────────────────────────────────────

  it "shows the four-tab strip" do
    within ".main-tabs-menu" do
      tab_labels = all("li").map { |li| li.text.strip }
      expect(tab_labels).to eq(%w(Main Questions Census Dashboard))
    end
  end

  # ── Save persists authentication settings ────────────────────────────────

  it "saves the selected credentials and redirects back to census" do
    # The form starts empty — tick the "Member number" credential and save.
    # memberNumber maps to "Member number" via CensusMember.field_label.
    within "#census-election-form #js-census-authentication" do
      check "Member number", allow_label_click: true
    end

    # The sticky Save button carries `.hide` (display:none) at load and
    # census.js drops it once auth is configured. In Chrome-based drivers
    # a click on a display:none element raises "element not interactable"
    # regardless of the Capybara `visible: :all` filter, so submit the
    # form directly.
    find_by_id("census-election-form").native.submit

    # A successful save redirects back to census#show.
    expect(page).to have_current_path(election_path.election_census_path(election))

    election.reload
    expect(election.census_auth_fields).to include("memberNumber")
  end
end
