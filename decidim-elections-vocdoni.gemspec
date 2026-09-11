# frozen_string_literal: true

$LOAD_PATH.push File.expand_path("lib", __dir__)

require "decidim/elections/vocdoni/version"

Gem::Specification.new do |s|
  s.version = Decidim::Elections::Vocdoni::VERSION
  s.authors = ["Vocdoni"]
  s.email = ["info@vocdoni.org"]
  s.license = "AGPL-3.0-or-later"
  s.homepage = "https://github.com/vocdoni/decidim-elections-vocdoni"
  # Decidim 0.33 requires Ruby 3.4, and this module is only ever installed
  # alongside it. Saying anything looser here would advertise a floor that
  # cannot actually be resolved.
  s.required_ruby_version = "~> 3.4"

  s.name = "decidim-elections-vocdoni"
  s.summary = "Verifiable elections for Decidim, powered by Vocdoni"
  s.description = "A Decidim component that runs elections on the Vocdoni protocol through " \
                  "the Vocdoni SaaS API. Ballots are cast and signed in the voter's browser; " \
                  "the Decidim server never sees a vote and requires no Node.js runtime."

  s.metadata = {
    "bug_tracker_uri" => "https://github.com/vocdoni/decidim-elections-vocdoni/issues",
    "changelog_uri" => "https://github.com/vocdoni/decidim-elections-vocdoni/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://github.com/vocdoni/decidim-elections-vocdoni#readme",
    "source_code_uri" => "https://github.com/vocdoni/decidim-elections-vocdoni",
    "rubygems_mfa_required" => "true"
  }

  # Tracked files only, so a release can never pick up a stray build artefact,
  # a generated dummy app or somebody's `.env`. This is how every Decidim gem
  # builds its manifest.
  #
  # `public/` is in the list because it carries the built voting page
  # (`public/vocdoni/vote.html` and friends). That is a build artefact which is
  # committed on purpose: the page has to be there the moment the gem is
  # installed, with no npm and no `assets:precompile` in between.
  #
  # `lib/decidim/elections/vocdoni/test/` ships too — a downstream module needs the
  # factories to write its own specs. The voting page's *own* tests do not: they
  # are a development concern and would only add weight.
  s.files = Dir.chdir(__dir__) do
    tracked = `git ls-files -z`.split("\x0")

    tracked.select do |f|
      next false if f.end_with?(".test.js", "voting_page_fixture.js")

      f.start_with?(*%w(app/ config/ db/ lib/ public/)) ||
        f.start_with?("docs/") ||
        %w(CHANGELOG.md LICENSE README.md Rakefile).include?(f)
    end
  end

  s.add_dependency "decidim-admin", *Decidim::Elections::Vocdoni::DECIDIM_COMPAT_VERSION
  s.add_dependency "decidim-core", *Decidim::Elections::Vocdoni::DECIDIM_COMPAT_VERSION
  s.add_dependency "faraday", "~> 2.9"
  s.add_dependency "faraday-retry", "~> 2.2"

  # `decidim-dev` and `decidim-participatory_processes` are development
  # dependencies of this module, and are deliberately declared in the `Gemfile`
  # rather than here. While Decidim 0.33 is unreleased the Gemfile has to pull
  # them from a git branch or a local path, and a gemspec development dependency
  # with a version constraint conflicts with that — Bundler warns on every
  # `bundle install`. Move them here once 0.33.0 is on RubyGems.
end
