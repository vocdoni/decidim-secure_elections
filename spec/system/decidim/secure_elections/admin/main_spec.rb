# frozen_string_literal: true

require "spec_helper"

# The Main tab: three collapsible accordion cards inside one form.
#
# What used to be three separate wizard screens (Details + Schedule +
# a ballot-wide Result visibility on the Questions form) collapses
# into this one page. The tab strip stays visible above; the cards
# are `.card.form-*` blocks with `data-controller="accordion"` and a
# `.card-divider-button` toggle, matching the DOM contract on
# `try.decidim.org` verbatim.
describe "Admin Main tab" do
  include_context "when managing a component as an admin"

  let(:manifest_name) { "vocdoni" }
  let(:election_path) { Decidim::EngineRouter.admin_proxy(component) }
  let!(:election) { create(:vocdoni_election, component:, skip_injection: true) }

  before do
    visit election_path.edit_election_path(election)
  end

  it "renders exactly three accordion cards in the expected order" do
    titles = all(".card .card-divider-button .card-title").map { |el| el.text.strip }

    expect(titles).to eq([
                           "Basic info",
                           "Calendar",
                           "Results availability"
                         ])
  end

  it "wires each card body as a role=region panel" do
    %w(panel-basic panel-calendar panel-results).each do |panel_id|
      expect(page).to have_css("##{panel_id}[role='region']")
    end
  end

  # Results availability is a two-value radio — `per_question` is
  # deliberately excluded because vd's protocol does not support it.
  it "offers only real_time and after_end as results-availability options" do
    within "#panel-results" do
      expect(page).to have_field("election_results_availability_real_time")
      expect(page).to have_field("election_results_availability_after_end")
      expect(page).to have_no_field("election_results_availability_per_question")
    end
  end

  it "exposes the manual_start checkbox on the calendar card" do
    within "#panel-calendar" do
      expect(page).to have_field(name: "election[manual_start]")
    end
  end

  it "persists the new attributes on save and continue" do
    within "#panel-results" do
      choose("election_results_availability_real_time")
    end
    within "#panel-calendar" do
      check("election_manual_start")
    end

    click_button "Save and continue"

    election.reload
    expect(election.results_availability).to eq("real_time")
    expect(election).to be_manual_start
  end
end
