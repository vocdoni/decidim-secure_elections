# frozen_string_literal: true

require "spec_helper"

# The public side of the module, in a real browser.
#
# Everything below is asserted somewhere in the unit specs too. What is not
# asserted anywhere else is that the pieces *render together*: the cells, the
# helpers, the icon registry, the Tailwind classes the module contributes and
# the voting link builder all have to agree for a participant to see a Vote
# button, and each of those has a way of failing that leaves every unit spec
# green.
describe "Explore elections" do
  include_context "with a component"

  let(:manifest_name) { "vocdoni" }
  let(:organization) { create(:organization) }
  # `skip_injection` keeps Decidim's XSS-probe payload out of the titles; this
  # spec is about layout, and the probe belongs to the specs that test escaping.
  let!(:election) { create(:vocdoni_election, :on_chain, component:, skip_injection: true) }

  before do
    switch_to_host(organization.host)
  end

  describe "the election list" do
    it "lists the published elections and not the drafts" do
      draft = create(:vocdoni_election, component:, skip_injection: true)

      visit_component

      expect(page).to have_text(translated(election.title))
      expect(page).to have_no_text(translated(draft.title))
    end
  end

  describe "the election page" do
    before do
      visit resource_locator(election).path
    end

    it "shows the election, its state and its questions" do
      expect(page).to have_css("h1", text: translated(election.title))
      expect(page).to have_css(".vocdoni-status", text: "Voting open")
      expect(page).to have_text("Questions")
      expect(page).to have_text(translated(election.questions.first.body))
    end

    # The link is built by `VotingPageUrl`, points at a file served by the
    # engine's own middleware rather than by a route, and carries the whole
    # election in one packed parameter. Nothing else on the public side has as
    # many ways to be quietly wrong.
    it "offers a voting link that opens the static voting page" do
      href = URI.parse(find_link("Vote")[:href])

      expect(href.path).to eq(Decidim::Elections::Vocdoni::Engine::VOTE_PATH)

      packed = href.query.delete_prefix("v=")
      decoded = Decidim::Elections::Vocdoni::VotingPageUrl.decode(packed)

      expect(decoded[:api]).to eq(Decidim::Elections::Vocdoni.api_url)
      expect(decoded[:process]).to eq(election.vocdoni_process_id)
    end

    it "explains what the voter will be asked for" do
      expect(page).to have_text("How this election works")
      expect(page).to have_text("Your ballot is encrypted and signed in your browser")
    end
  end

  # An election that is not on chain has no process to open, so the aside says
  # so rather than offering a link that could only fail.
  describe "an election that is not on chain yet" do
    let!(:election) { create(:vocdoni_election, :published, :ready_to_publish, component:, skip_injection: true) }

    it "says why there is nothing to vote on instead of linking to a dead page" do
      visit resource_locator(election).path

      expect(page).to have_no_link("Vote")
      expect(page).to have_text("This election has not been set up for voting yet")
    end
  end
end
