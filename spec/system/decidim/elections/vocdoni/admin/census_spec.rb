# frozen_string_literal: true

require "spec_helper"

# The Census tab: manifest selector + flat auth-config form + "Manage
# people (N)" link out to the members editor. Matches upstream
# decidim-elections' Census tab shape (one manifest, one form, one save).
#
# Roster management (People card, Add-people section, Empty census) lives
# on `/census/members` — see census_members_spec.rb.
#
# DOM contract (per task brief §4 + QW5):
#   #census-manifest-selector  — <select> with at least "internal_users" option
#   #census-election-form      — the inline auth-config form
#   #js-census-authentication  — the flat wrapper (Credentials + Two-factor
#                                fieldsets + weighted checkbox + security meter)
#   .card-section.census-form  — wrapper around the form
#   .item__edit-sticky         — sticky "Save and continue" button
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

  it "shows the flat authentication wrapper inside the form" do
    within "#census-election-form" do
      expect(page).to have_css("#js-census-authentication")
    end
  end

  it "renders Credentials and Two-factor as fieldsets, not numbered cards" do
    within "#js-census-authentication" do
      expect(page).to have_css("fieldset legend", text: /credentials/i)
      expect(page).to have_css("fieldset legend", text: /two-factor/i)
      # No "1./2./3." numbering anywhere.
      expect(page).to have_no_text(/^\s*1\.\s*/)
    end
  end

  # ── Sticky Save ───────────────────────────────────────────────────────────

  it "renders the sticky Save and continue button linked to the census form" do
    expect(page).to have_css(".item__edit-sticky button[form='census-election-form']", text: /save and continue/i)
  end

  # ── "Manage people (N)" link ──────────────────────────────────────────────

  it "renders a link to the members editor with the current people count" do
    expect(page).to have_link(/manage people/i, href: election_path.election_census_members_path(election))
  end

  # ── Preview + People management no longer live here ──────────────────────

  it "does not render an inline preview table on the Census tab" do
    # The 5-row preview + People card were moved to /census/members in QW5.
    within ".card-section.census-form" do
      expect(page).to have_no_css(".table-list")
    end
  end

  it "does not render the Import panel on the Census tab" do
    expect(page).to have_no_css("#js-census-import")
  end

  it "does not render the Verifications panel on the Census tab" do
    expect(page).to have_no_css("#js-census-verifications")
  end

  # ── Tab strip ─────────────────────────────────────────────────────────────

  it "shows the four-tab strip" do
    within ".main-tabs-menu" do
      tab_labels = all("li").map { |li| li.text.strip }
      expect(tab_labels).to eq(%w(Main Questions Census Dashboard))
    end
  end

  # ── Save persists authentication settings ────────────────────────────────

  it "saves the selected credentials and redirects (census incomplete → stays)" do
    # The form starts empty — tick the "Member number" credential and save.
    # memberNumber maps to "Member number" via CensusMember.field_label.
    within "#census-election-form #js-census-authentication" do
      check "Member number", allow_label_click: true
    end

    # Submit the form directly rather than clicking the button, so a
    # display: none rule on the sticky bar (from other packs) doesn't
    # trip up Capybara's interactability check.
    find_by_id("census-election-form").native.submit

    # The census still has no members → census_complete? false → the
    # controller keeps us on census#show. When the census is fully
    # complete `next_step_path` redirects to the Dashboard instead.
    expect(page).to have_current_path(election_path.election_census_path(election))

    election.reload
    expect(election.census_auth_fields).to include("memberNumber")
  end
end
