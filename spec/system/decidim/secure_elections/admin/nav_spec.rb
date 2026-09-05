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
end
