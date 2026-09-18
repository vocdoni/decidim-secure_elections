# frozen_string_literal: true

require "spec_helper"

# The four-tab strip that replaces the old six-step wizard navigation.
#
# Every editor screen must render exactly four tabs in this order:
# Main / Questions / Census / Dashboard. This spec drives the edit page
# because that is the first screen the tab strip appears on, and the
# edit page is always reachable (details are always the first step).
describe "Admin tab navigation" do
  include_context "when managing a component as an admin"

  let(:manifest_name) { "vocdoni" }
  let(:election_path) { Decidim::EngineRouter.admin_proxy(component) }
  let!(:election) { create(:vocdoni_election, component:, skip_injection: true) }

  before do
    visit election_path.edit_election_path(election)
  end

  it "renders exactly the four tabs in order" do
    within ".main-tabs-menu" do
      tab_labels = all("li").map { |li| li.text.strip }
      expect(tab_labels).to eq(%w(Main Questions Census Dashboard))
    end
  end

  # Dashboard is a disabled span pre-publish (matches upstream
  # decidim-elections). The Publish flow lives on its own confirmation
  # page reached from the row-level Actions dropdown, not on the
  # Dashboard tab.
  it "renders Dashboard as disabled pre-publish" do
    within ".main-tabs-menu" do
      dashboard_href = find("li", text: "Dashboard").find("a")["href"]
      expect(dashboard_href).to eq("#")
    end
  end

  context "when the election is on-chain" do
    let!(:election) do
      create(:vocdoni_election, :on_chain, component:, skip_injection: true, status: "ready")
    end

    before do
      visit election_path.election_dashboard_path(election)
    end

    it "renders Dashboard as an active link" do
      within ".main-tabs-menu" do
        expect(page).to have_link("Dashboard", href: election_path.election_dashboard_path(election))
      end
    end
  end
end
