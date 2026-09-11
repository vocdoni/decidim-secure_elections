# frozen_string_literal: true

require "spec_helper"

# The voting page is a static page shipped inside this gem: `npm run build:vote`
# writes it into `public/vocdoni/`, and the result is committed so that
# installing the gem is the only step between an operator and a working ballot.
#
# Nothing in Ruby can rebuild it, so these are the checks that keep the two
# halves honest: the files have to be there, they have to be packaged, and the
# strings the JavaScript reads have to exist in the locale files the build
# generated from `config/locales`.
describe "the built voting page" do # rubocop:disable RSpec/DescribeClass -- the subject is a directory of build output, not a class
  let(:engine_root) { Pathname.new(Decidim::Elections::Vocdoni::Engine.root) }
  let(:vote_root) { engine_root.join("public/vocdoni") }
  let(:english) { JSON.parse(vote_root.join("locales/en.json").read) }

  it "ships the page, the bundle, the stylesheet and the locale index" do
    %w(vote.html vote.js vote.css locales/index.json locales/en.json).each do |file|
      expect(vote_root.join(file)).to exist
    end
  end

  # `ActionDispatch::Static` serves whatever is under the engine's `public/`,
  # so this is the path an operator can rely on the moment the gem is installed.
  it "serves the page at the path the rest of the module links to" do
    expect(Decidim::Elections::Vocdoni::Engine::VOTE_PATH).to eq("/vocdoni/vote.html")
    expect(vote_root.join("vote.html")).to exist
  end

  it "is packaged in the gem" do
    files = Gem::Specification.load(engine_root.join("decidim-elections-vocdoni.gemspec").to_s).files

    expect(files).to include("public/vocdoni/vote.html", "public/vocdoni/vote.js")
  end

  # The page is set in Source Sans Pro, the face decidim-core ships, so that a
  # voter who has just left a Decidim page does not meet a different one. The
  # files are served from beside the stylesheet rather than from a font host: a
  # voting page must not tell a third party that somebody is voting. If they go
  # missing the page still works, silently, in the wrong typeface — which is
  # exactly the kind of failure nothing else here would catch.
  describe "the type face" do
    let(:faces) { %w(source-sans-pro-regular source-sans-pro-600 source-sans-pro-700) }

    it "ships every weight the stylesheet asks for, and packages them" do
      files = Gem::Specification.load(engine_root.join("decidim-elections-vocdoni.gemspec").to_s).files
      css = vote_root.join("vote.css").read

      faces.each do |face|
        expect(vote_root.join("fonts/#{face}.woff2")).to exist
        expect(files).to include("public/vocdoni/fonts/#{face}.woff2")
        expect(css).to include("fonts/#{face}.woff2")
      end
    end

    it "asks for no font from anywhere else" do
      expect(vote_root.join("vote.css").read).not_to match(%r{url\(\s*["']?(https?:)?//})
    end
  end

  describe "the shell" do
    subject(:html) { vote_root.join("vote.html").read }

    it "loads the bundle and the stylesheet from beside itself" do
      expect(html).to include(%(src="vote.js"))
      expect(html).to include(%(href="vote.css"))
    end

    # A live region has to be in the document before it is written to for the
    # update to be announced, so it is markup rather than something the page
    # builds on its way past.
    it "carries the shared live region and the no-JavaScript fallback" do
      expect(html).to include(%(id="js-vocdoni-vote-status"), %(aria-live="polite"))
      expect(html).to include("<noscript>")
      expect(html).to include(%(id="js-vocdoni-vote-unavailable"))
    end

    # A link that reached the voter without the election it names will reach
    # them without it every time it is opened, so the "reload the page" fallback
    # is the one piece of advice that cannot work.
    it "tells a voter holding an incomplete link to ask for a new one" do
      expect(html).to include(%(id="js-vocdoni-vote-incomplete"))
      expect(html).to include("Reloading the page will not fix it")
    end

    it "asks not to be indexed, and not to leak the election in a referrer" do
      expect(html).to include(%(name="robots"), %(name="referrer"))
    end
  end

  # The page used to live at `booth.html` and links to that address were sent to
  # real voters, so it stays — as a redirect, and only for them.
  describe "the legacy address" do
    subject(:html) { vote_root.join("booth.html").read }

    it "is still shipped, and still packaged" do
      files = Gem::Specification.load(engine_root.join("decidim-elections-vocdoni.gemspec").to_s).files

      expect(Decidim::Elections::Vocdoni::Engine::LEGACY_VOTE_PATH).to eq("/vocdoni/booth.html")
      expect(files).to include("public/vocdoni/booth.html")
    end

    # The election travels in the query string, so a redirect that dropped it
    # would land every one of those voters on "this voting link is incomplete".
    it "forwards to the voting page with the query string intact" do
      expect(html).to include('window.location.replace("vote.html" + window.location.search')
      expect(html).to include(%(name="robots"), %(name="referrer"))
    end
  end

  describe "the locale files" do
    it "names every locale it ships in the index the page reads first" do
      index = JSON.parse(vote_root.join("locales/index.json").read)

      expect(index["locales"]).to include("en")
      expect(index["default"]).to eq("en")

      index["locales"].each do |locale|
        expect(vote_root.join("locales/#{locale}.json")).to exist
      end
    end

    it "carries every group of strings the page builds its markup from" do
      expect(english.keys).to include(
        "auth", "ballot", "blocked", "error", "errors", "fields", "loading",
        "otp", "progress", "receipt", "review", "status", "submit", "validation"
      )
    end

    # The page renders one message per `ErrorCode`. A code with no message
    # would fall back to printing the code itself at a voter.
    it "has a message for every failure the page can classify" do
      expect(english["errors"].keys).to match_array(
        %w(auth_cooldown auth_rejected ballot_unsupported keys_unavailable network
           otp_expired otp_rejected otp_resend_failed process_unavailable
           relay_rejected relay_unconfirmed sign_rejected unknown)
      )
    end

    # A census normally authenticates on a credential, but the admin form does
    # allow `email`/`phone` to be one (ARCHITECTURE §4c-bis), and the page then
    # labels that input from the same table. Both sets have to be covered or a
    # voter meets an input labelled `memberNumber`.
    it "labels every census field the page can be asked for" do
      expect(english["fields"].keys).to include(
        *Decidim::Elections::Vocdoni::Election::AUTH_FIELDS,
        *Decidim::Elections::Vocdoni::Election::TWO_FA_FIELDS
      )
    end

    it "was generated from config/locales rather than written by hand" do
      expect(english["exit"]).to eq(I18n.t("decidim.elections.vocdoni.votes.page.exit", locale: :en))
      expect(english["question_number"]).to eq(I18n.t("decidim.elections.vocdoni.elections.show.question_number", locale: :en))
    end

    # Every string a voter can meet used to call this a "voting booth". The word
    # is gone from the interface, and a rebuild must not bring it back.
    it "never says booth at a voter" do
      expect(english.to_s).not_to match(/booth/i)
    end
  end
end
