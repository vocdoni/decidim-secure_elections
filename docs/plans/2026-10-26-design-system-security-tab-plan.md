# Design system: Security tab and Dashboard card — implementation plan

Spec: inline below
Class: bounded
Repos and branches: /Users/ferran/Repos/decidim/decidim-secure_elections → feature/design-system-security-tab (base 8d1170e)

## Spec

### Problem
The admin Security tab (`app/views/decidim/elections/vocdoni/admin/security/*`,
`app/packs/stylesheets/decidim/elections/vocdoni/admin/security.scss`) was built before the
Decidim 2026 redesign existed. Decidim's product team has since designed this exact tab and a
"Your security configuration" Dashboard card in Figma, on top of the new Decidim Design
System, whose tokens are landing in decidim/decidim#17722. The current tab differs from the
design in structure (two separate cards plus a "Why it matters" section and a summary line
that the design does not have), in components (icons on every point, boxed notes, a green
"Recommended" label) and in colours (legacy Tailwind names `text-gray-2`, `border-background-4`,
`bg-secondary/5` instead of Design System tokens). The Dashboard has no security card at all.

### Goals
1. The Security tab renders the Figma design pixel-for-structure: one outer card, a disclosure
   header, two option cards with footer bands, the "Recommended" pill, the inline "Good to
   know" row, and the one-time-code block inside the same card, shown only for the secret vote.
2. The Dashboard shows the "Your security configuration" card with the election's security
   sentence, styled like its sibling cards.
3. Every colour and type value comes from the Design System tokens as defined in
   decidim/decidim#17722, written as CSS custom properties with the Figma value as fallback,
   so the module renders identically before and after that PR reaches Decidim.
4. Nothing the admin can do today is lost: the radio choice, the two checkboxes, the save
   action, the disabled state of the code block for a simple vote, and the keyboard and
   screen-reader behaviour (radio labelled by the title, card described by its body).

### Non-goals
- The static voting page (`public/vocdoni/vote.html`, `app/packs/src/.../voter/`,
  `build/vote.mjs`): untouched, no rebuild.
- Upstream's tabs bar, Dashboard cards (status, calendar, results, main, questions, census),
  sidebar and header: upstream's; not restyled here.
- The hidden Vocdoni notification banner on the Dashboard frame.
- Catalan/Spanish translations (separate task M11 in the QA plan).
- Mobile-specific layouts: Figma only has the 1536 px desktop frame; keep today's breakpoint
  behaviour (two option columns from `xl`).

### Current state
- `show.html.erb` renders an `h1` "Security", then `_choice` (card 1 with icons per point,
  `.label.success` badge, boxed "Good to know" note, and the `_why_it_matters` partial),
  `_two_factor` (card 2 with a boxed note, icon labels, `help-text`), `_summary` (level pill
  and sentence), and the sticky save bar.
- `security.scss` (330 lines) is `@apply`-only with legacy tokens; scoped under
  `.vocdoni-security`.
- `security.js` toggles `.is-selected` on cards, enables/disables the code fieldset, and
  switches the summary line.
- `config/locales/security.en.yml` holds the copy under
  `decidim.elections.vocdoni.admin.security.show.{choice,why,two_factor,summary}`.
- Upstream `decidim-elections/app/views/decidim/elections/admin/elections/dashboard.html.erb`
  renders status + calendar + results (published) or subtitle + main + questions + census
  (unpublished). It has no view hook, Deface is not available, and the module has no way to
  add a card there today.
- Specs cover forms, commands, jobs and services only; there are no request or view specs.
- Design reference with every measurement and token: `docs/design/security-tab/README.md`
  and the three PNG targets next to it.

### Design
See `docs/design/security-tab/README.md`. Decisions (rulings) that shape the tasks:
- R1 Tokens are consumed as `var(--color-color-…, <fallback>)` through one SCSS token map
  (`app/packs/stylesheets/decidim/elections/vocdoni/admin/_tokens.scss`); spacing and radii use
  the standard Tailwind utilities whose values equal the Design System measures.
- R2 The Dashboard card is injected by prepending the module's view path to
  `Decidim::Elections::Admin::ElectionsController` (in the engine's `to_prepare`) with a copy
  of upstream's `dashboard.html.erb` that adds one `render` per branch of upstream's
  `if election.published?` (two lines: after Results, before Main). A spec pins the SHA-256 of
  upstream's file so any upstream change fails the suite and forces a re-sync. The copy is
  marked with a header comment naming the upstream path and the pinned Decidim commit.
- R3 The Dashboard card reuses upstream's `card`/`card-divider`/`card-title` chrome.
- R4 The one-time-code block is server-rendered `hidden` (and the fieldset `disabled`) when
  the simple vote is selected; `security.js` toggles both without saving.
- R5 `_why_it_matters.html.erb`, the summary line on the Security tab, their SCSS and i18n
  keys (`show.why.*`, `show.summary.levels.*`, `show.choice.*.summary`,
  `show.two_factor.simple_note`, `show.choice.selected`, `show.summary.title`) are removed. `show.summary.sentences.*`
  stays and feeds the Dashboard card.
- R6 The `h1` uses upstream's `decidim.elections.admin.elections.edit.title` ("Edit election");
  the browser title keeps `show.title` ("Security").
- R7 The section header is a native `<details open>`/`<summary>` so the chevron is a working
  disclosure without JavaScript.
- R8 Option points are plain `list-disc` items; the per-point icons and the option summary
  line are dropped.
- R9 The "Recommended" pill is a positioned `<span>` on the secure card's top edge, with the
  info-light background and secondary text; it stays referenced by `aria-describedby`.
- R10 Selectors for JavaScript stay `js-` ids or `data-` attributes; restyling must not touch
  `security.js` selectors.

### Acceptance criteria
- [ ] AC1 Request spec: `GET …/elections/:id/security` as an admin renders one `.vocdoni-security__card` containing `details[open] > summary` with the legend, two `[data-security-choice-card]` with `ul.list-disc` and a footer band, the "Recommended" pill, the "Good to know" row, and the one-time-code block; the block carries `hidden` when `enable_vocdoni` is false and not when true. No `why_it_matters`, no `#js-security-summary`.
- [ ] AC2 Request spec: the same page for a non-admin participant and for an anonymous visitor is refused (redirect or 404), as today.
- [ ] AC3 Request spec: `GET …/elections/:id/dashboard` as an admin renders `.vocdoni-security-summary` with the sentence for the election's level, after the results block for a published election and before the Main card for an unpublished one.
- [ ] AC4 Spec: the SHA-256 of the installed `decidim-elections/app/views/decidim/elections/admin/elections/dashboard.html.erb` equals the pinned value; the module's copy differs from upstream only by the added render line (diff asserted).
- [ ] AC5 `security.scss` contains no `text-gray-*`, `border-background-*`, `bg-background*`, `bg-secondary/*` utilities; every colour is a `var(--color-color-…, #…)` from `_tokens.scss` (grep spec).
- [ ] AC6 `bundle exec i18n-tasks unused` and `missing` report nothing for `en` (removed keys gone, new keys present); `bundle exec rubocop`, `npm run lint`, `npm run stylelint` and `npm test` are green; `git diff --quiet -- public/vocdoni` holds (no voting-page change).
- [ ] AC7 Visual check by the controller in the development app against the three PNG targets, both radio states, at 1536 px; contrast pairs from the design README recorded as SCSS comments.
- [ ] AC8 CHANGELOG "Unreleased" entry describing the redesign and the Dashboard card.

### Constraints
See Global Constraints.

## Global Constraints
- Commit convention: conventional commits `type(scope): lowercase summary`, English, imperative, no AI attribution and no Co-Authored-By or similar trailers (CONTRIBUTING.md: imperative mood, capitalised subject is accepted; keep the type prefix).
- Never push; commit with explicit paths only; never switch branches; never run git stash.
- Build output and scratch copies under `~/.cache/decidim-secure_elections/`, never `/tmp`.
- Ruby 3.4.7, Node 24.18.0 through mise: run every command after `source ~/Repos/decidim/dev-env.sh` (it sets `DECIDIM_PATH`, `BUNDLE_PATH`, Postgres/Redis env and the right PATH). Postgres and Redis run in Docker (`~/Repos/decidim/dev-services`).
- Specs run from the module root with `bundle exec rspec <path>`; they need the generated dummy app at `spec/decidim_dummy_app` (gitignored, already generated; do not regenerate it, do not edit it).
- Do not touch `public/vocdoni/**`, `app/packs/src/decidim/elections/vocdoni/voter/**`, `build/**`, `config/locales/en.vote.yml`.
- Do not change `mise.local.toml`, `Gemfile`, `Gemfile.lock` or anything under `development_app/`.
- JavaScript selectors are `js-` ids or `data-` attributes, never CSS classes (CONTRIBUTING.md).
- All UI must meet WCAG 2.1 AA; use the contrast table in `docs/design/security-tab/README.md` and do not introduce colour pairs outside it without measuring.
- Only `en` locale files are edited; `config/locales/security.en.yml` stays valid YAML with its comments. Do not run `i18n-tasks normalize` (it strips the comments and rewrites `en.vote.yml`); `i18n-tasks missing` and `unused` must be clean.
- Never print, log or commit secrets (the `VOCDONI_API_KEY` in `mise.local.toml`).
- Lint before committing: `bundle exec rubocop --parallel`, `npm run lint`, `npm run stylelint`.

## Review Focus
- `lib/decidim/elections/vocdoni/engine.rb` `to_prepare` block: the prepended view path must only affect `Decidim::Elections::Admin::ElectionsController` and must not shadow any other upstream view (list the files in the prepended directory in the spec).
- `app/views/overrides/decidim/elections/admin/elections/dashboard.html.erb` (module copy): byte-identical to upstream except the header comment and the two added render lines; the drift spec must fail on any upstream change.
- `app/controllers/decidim/elections/vocdoni/admin/security_controller.rb`: unchanged permission checks (`enforce_permission_to`); the request specs must prove denial for non-admins.
- `app/views/decidim/elections/vocdoni/admin/security/_choice.html.erb`: `aria-labelledby`/`aria-describedby` wiring survives the restyle; radios still post `enable_vocdoni` "true"/"false".
- `security.js`: the summary-sync code is removed; the card and fieldset toggles keep working without the summary element present.

## Task order and parallelism

Every code block below was checked in an APFS clone of this branch under
`~/.cache/decidim-secure_elections/scratch/repo` (base `b85f88b`, dummy app
included): with all seven tasks applied, `bundle exec rspec` gave
`142 examples, 0 failures`, `npm test` 205 passed, `bundle exec rubocop
--parallel` no offenses, `npm run lint` 0 errors, `npm run stylelint` clean,
`i18n-tasks missing`/`unused` clean, and the dummy app's webpack build compiled
the new stylesheet without errors. The red counts in Task 1 come from running
the final spec files against the unchanged `b85f88b` tree. Other checks run on
the drafts: every ERB compiled through ActionView's Erubi handler and
syntax-checked, Ruby files with `ruby -c`, YAML with `YAML.load_file`, JS with
ESLint (via `--stdin-filename` at the repo path) and Jest against the old and
the new `security.js`, every commit line below replayed in order in the clone
(clean tree after Task 7), and every code block in this plan compared byte for
byte with the verified files (the override generation command reproduces the
verified copy's SHA-256).

| Task | Depends on | Repo/files | May run in parallel with |
|---|---|---|---|
| 1 Specs first (red) | — | `spec/requests/…/admin/{security,dashboard}_spec.rb`, `spec/lib/…/vocdoni/{dashboard_override,security_stylesheet}_spec.rb`, `spec/forms/…/security_form_spec.rb` | none (everything waits for it) |
| 2 Tokens and stylesheet | 1 | `app/packs/stylesheets/…/admin/{_tokens,security}.scss` | 3, 4, 7 |
| 3 Security tab views and copy | 1 | `app/views/…/admin/security/*`, `config/locales/security.en.yml` | 2, 4, 7 |
| 4 Security tab script | 1 | `app/packs/src/…/admin/security{,.test}.js` | 2, 3, 7 |
| 5 Dashboard card | 3 (shares `security.en.yml`) | `app/views/…/admin/dashboard/_security.html.erb`, `app/views/overrides/…/dashboard.html.erb`, `lib/…/engine.rb`, `app/forms/…/security_form.rb`, `config/locales/security.en.yml` | 2, 4, 7 |
| 6 i18n-tasks configuration | 3, 5 | `config/i18n-tasks.yml` | 2, 4, 7 |
| 7 CHANGELOG | — (after 1 for history order) | `CHANGELOG.md` | 2, 3, 4, 5, 6 |

Disjoint pairs: 2, 3, 4 and 7 touch no common file and may run side by side
once Task 1 is committed. 3 and 5 share `config/locales/security.en.yml`, so 5
waits for 3; 6 needs the final views (3, 5) for its i18n checks. Parallel
implementers in one working tree must commit with explicit paths only (as
every commit line below does).

Paths abbreviated with `…` in the table are spelled out in each task.

## Tasks

Conventions for every task:

- Run every command from the module root after
  `source ~/Repos/decidim/dev-env.sh` (it `cd`s into the module root).
- The dummy app (`spec/decidim_dummy_app`) is generated; never regenerate or
  edit it. Request specs compile the packs on first use (Shakapacker watches
  the module's `app/packs` through Decidim's runtime config); a compile error
  does not fail the specs, so Task 2 checks the build log explicitly.
- "Full content" means: replace the whole file with the block. Edits are given
  as exact `old` → `new` pairs.

### Task 1: Specs first (red)
Model: sonnet   Repo: /Users/ferran/Repos/decidim/decidim-secure_elections
Files:
- `spec/requests/decidim/elections/vocdoni/admin/security_spec.rb` (new)
- `spec/requests/decidim/elections/vocdoni/admin/dashboard_spec.rb` (new)
- `spec/lib/decidim/elections/vocdoni/dashboard_override_spec.rb` (new)
- `spec/lib/decidim/elections/vocdoni/security_stylesheet_spec.rb` (new)
- `spec/forms/decidim/elections/vocdoni/admin_forms/security_form_spec.rb` (edit)

Goal: write the specs for AC1–AC5 before any implementation, so tasks 2–5 each
turn a known set of red examples green. Request specs follow Decidim's
conventions: `Decidim::EngineRouter.admin_proxy(component)` for paths, a
`HOST` header for the organization, Warden's `login_as` (included for
`type: :request` by decidim-dev), the upstream `:election` factory with
`:with_token_csv_census` (the Dashboard requires `census_ready?`, the Security
tab requires `editable?`, i.e. unpublished) and the module's `:vocdoni_process`
factory. Denials follow `.ai/security.md` §1: a non-admin participant gets a
404 (Decidim's admin routes only match for admins) and an anonymous visitor is
redirected to sign in, for both GET and PUT, and the PUT creates no sidecar.

The pinned SHA-256 is of
`/Users/ferran/Repos/decidim/decidim/decidim-elections/app/views/decidim/elections/admin/elections/dashboard.html.erb`
at decidim/decidim `4c4d062fb9db171daac7fdad05d3bc5154ee15b2` (= `origin/develop`
on 2026-10-26), computed with `shasum -a 256`:
`7353b4ce482a28f4af761398d96cb3af4a8c93efaf0412454fb3d1e7b7927f27`.

Step 1: write the failing tests

`spec/requests/decidim/elections/vocdoni/admin/security_spec.rb` (full content):
```ruby
# frozen_string_literal: true

require "spec_helper"

# The Security tab as an admin sees it (AC1), and who may not see or change
# it (AC2). The permission check is the controller's
# `enforce_permission_to(:update, :census, election:)`, unchanged by the
# redesign; these examples are what proves it still holds.
module Decidim
  module Elections
    module Vocdoni
      describe "Admin Security tab" do
        let(:organization) { component.organization }
        let(:component) { create(:elections_component) }
        let!(:election) { create(:election, :with_token_csv_census, component:) }
        let(:headers) { { "HOST" => organization.host } }
        let(:security_path) { Decidim::EngineRouter.admin_proxy(component).election_security_path(election) }
        let(:html) { response.parsed_body }

        def sidecar
          Vocdoni::Process.find_by(decidim_election_id: election.id)
        end

        context "when an admin opens the tab" do
          let(:admin) { create(:user, :admin, :confirmed, organization:) }

          before do
            login_as admin, scope: :user
            get security_path, headers:
          end

          it "renders everything inside one card under a disclosure header" do
            expect(response).to have_http_status(:ok)
            expect(html.css(".vocdoni-security__card").size).to eq(1)

            summary = html.at_css(".vocdoni-security__card details[open] > summary")
            expect(summary).to be_present
            expect(summary.text).to include("How do you want to run this vote?")
            expect(html.at_css("h1.item_show__header-title").text.strip).to eq("Edit election")
          end

          it "renders the two option cards with plain points and a footer band" do
            cards = html.css(".vocdoni-security__card [data-security-choice-card]")

            expect(cards.map { |card| card["data-security-choice-card"] }).to eq(%w(simple secure))
            cards.each do |card|
              expect(card.css("ul.list-disc > li").size).to eq(4)
              expect(card.css("ul.list-disc svg")).to be_empty
              expect(card.at_css(".vocdoni-choice__footer").text).to include("Best for:")
            end
          end

          it "keeps the radios labelled by the title and described by the card" do
            secure = html.at_css("#security_choice_secure")
            simple = html.at_css("#security_choice_simple")

            expect(secure["name"]).to eq("security[enable_vocdoni]")
            expect(secure["value"]).to eq("true")
            expect(simple["value"]).to eq("false")
            expect(secure["aria-describedby"]).to eq("security-choice-badge security-choice-secure-description")
            expect(html.at_css("label[for='security_choice_secure']").text.strip).to eq("Secret, verifiable vote")
          end

          it "puts the Recommended pill on the secure card and the Good to know row after the cards" do
            badge = html.at_css("[data-security-choice-card='secure'] > #security-choice-badge")

            expect(badge.text.strip).to eq("Recommended for binding decisions")
            expect(badge["class"]).not_to include("label")
            expect(html.at_css("#js-security-choice [data-security-good-to-know]").text).to include("Good to know:")
          end

          it "renders the one-time code block hidden and disabled for a simple vote" do
            block = html.at_css(".vocdoni-security__card fieldset#js-security-two-factor")

            expect(block).to be_present
            expect(block.has_attribute?("hidden")).to be(true)
            expect(block.has_attribute?("disabled")).to be(true)
            expect(block.at_css("#security_email")).to be_present
            expect(block.at_css("#security_sms")).to be_present
          end

          it "no longer renders the removed sections" do
            expect(response.body).not_to include("vocdoni-why")
            expect(response.body).not_to include("Why it matters")
            expect(html.at_css("#js-security-summary")).to be_nil
          end

          context "when the election has opted in to the secret vote" do
            let!(:election) do
              create(:election, :with_token_csv_census, component:).tap do |record|
                create(:vocdoni_process, election: record)
              end
            end

            it "renders the one-time code block visible and enabled" do
              block = html.at_css("fieldset#js-security-two-factor")

              expect(block.has_attribute?("hidden")).to be(false)
              expect(block.has_attribute?("disabled")).to be(false)
              expect(html.at_css("[data-security-choice-card='secure']")["class"]).to include("is-selected")
            end
          end
        end

        context "when a participant who is not an admin opens the tab" do
          let(:participant) { create(:user, :confirmed, organization:) }

          before { login_as participant, scope: :user }

          # Decidim's admin routes only match for admins, so the tab does not
          # exist for anybody else.
          it "is refused" do
            get(security_path, headers:)

            expect(response).to have_http_status(:not_found)
            expect(response.body).not_to include("vocdoni-security__card")
          end

          it "cannot opt the election in" do
            put(security_path, params: { security: { enable_vocdoni: "true", email: "1" } }, headers:)

            expect(response).to have_http_status(:not_found)
            expect(sidecar).to be_nil
          end
        end

        context "when an anonymous visitor opens the tab" do
          it "is sent to sign in" do
            get(security_path, headers:)

            expect(response).to have_http_status(:found)
            expect(response.location).to include("/users/sign_in")
          end

          it "cannot opt the election in" do
            put(security_path, params: { security: { enable_vocdoni: "true" } }, headers:)

            expect(response).to have_http_status(:found)
            expect(sidecar).to be_nil
          end
        end
      end
    end
  end
end
```

`spec/requests/decidim/elections/vocdoni/admin/dashboard_spec.rb` (full content):
```ruby
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
      end
    end
  end
end
```

`spec/lib/decidim/elections/vocdoni/dashboard_override_spec.rb` (full content):
```ruby
# frozen_string_literal: true

require "spec_helper"
require "digest"

# The Dashboard card needs one line in upstream's dashboard, which has no view
# hook, so the module ships a copy of that file (see its header) and the engine
# prepends its directory to `Decidim::Elections::Admin::ElectionsController`
# only. These examples keep the copy honest: any upstream change to the file
# fails here until the copy is re-synced.
module Decidim
  module Elections
    module Vocdoni
      describe "Dashboard view override" do
        # SHA-256 of decidim-elections/app/views/decidim/elections/admin/elections/dashboard.html.erb
        # at decidim/decidim 4c4d062fb9db171daac7fdad05d3bc5154ee15b2.
        let(:pinned_digest) { "7353b4ce482a28f4af761398d96cb3af4a8c93efaf0412454fb3d1e7b7927f27" }
        let(:relative_path) { "decidim/elections/admin/elections/dashboard.html.erb" }
        let(:overrides) { Engine.root.join("app/views/overrides") }
        let(:upstream_path) { Decidim::Elections::Engine.root.join("app/views", relative_path) }
        let(:copy_path) { overrides.join(relative_path) }
        let(:added_line) { %(    <%= render partial: "decidim/elections/vocdoni/admin/dashboard/security" %>\n) }

        let(:copy_lines) { copy_path.readlines }
        let(:header_end) { copy_lines.index("%>\n") }
        let(:copy_body) { copy_lines.drop(header_end + 1) }

        it "is synced with the installed upstream dashboard" do
          digest = Digest::SHA256.file(upstream_path).hexdigest
          hint = "#{upstream_path} changed upstream: re-copy it into #{copy_path}, re-add the two render lines, " \
                 "and update the pinned commit (file header) and digest (this spec)"

          expect(digest).to eq(pinned_digest), hint
        end

        it "opens with a header naming the upstream file and the pinned commit" do
          header = copy_lines.take(header_end + 1).join

          expect(copy_lines.first).to eq("<%#\n")
          expect(header).to include("decidim-elections/app/views/#{relative_path}")
          expect(header).to include("4c4d062fb9db171daac7fdad05d3bc5154ee15b2")
        end

        it "differs from upstream only by the two added render lines" do
          expect(copy_body.count(added_line)).to eq(2)
          expect(copy_body - [added_line]).to eq(upstream_path.readlines)
        end

        it "adds the card after Results when published and before Main when not" do
          expect(copy_body[copy_body.index(added_line) - 1]).to include("admin/dashboard/results")
          expect(copy_body[copy_body.rindex(added_line) + 1]).to include("admin/dashboard/main")
        end

        it "shadows no other upstream view" do
          files = Dir.glob("**/*", base: overrides).select { |path| overrides.join(path).file? }

          expect(files).to eq([relative_path])
        end

        it "is on the view path of the elections admin controller only" do
          expect(Decidim::Elections::Admin::ElectionsController.view_paths.map(&:to_s).first).to eq(overrides.to_s)
          expect(Decidim::Elections::Admin::ApplicationController.view_paths.map(&:to_s)).not_to include(overrides.to_s)
          expect(ActionController::Base.view_paths.map(&:to_s)).not_to include(overrides.to_s)
        end
      end
    end
  end
end
```

`spec/lib/decidim/elections/vocdoni/security_stylesheet_spec.rb` (full content):
```ruby
# frozen_string_literal: true

require "spec_helper"

# Every colour on the Security tab and the Dashboard card is a Design System
# token from `_tokens.scss` (a CSS custom property from decidim/decidim#17722
# with the Figma value as fallback), never a legacy Tailwind colour utility
# or a raw value. See docs/design/security-tab/README.md.
module Decidim
  module Elections
    module Vocdoni
      describe "Security tab stylesheet" do
        let(:directory) { Engine.root.join("app/packs/stylesheets/decidim/elections/vocdoni/admin") }
        let(:tokens) { directory.join("_tokens.scss").read(encoding: "UTF-8") }
        # Line comments carry the contrast notes and prose; only code counts.
        let(:code) { directory.join("security.scss").read(encoding: "UTF-8").gsub(%r{//[^\n]*}, "") }

        it "uses no Tailwind colour utility" do
          expect(code).not_to match(/(?<![\w$-])(?:text|bg|border|fill|stroke|outline|accent|ring|decoration)-(?:gray|background|secondary|primary|tertiary|black|white|success|alert|warning|neutral)\b/)
        end

        it "writes no raw colour" do
          expect(code).not_to match(/#\h{3,8}\b|\b(?:rgba?|hsla?)\(/)
        end

        it "takes every colour declaration from a token" do
          declarations = code.scan(/^\s*(color|background(?:-color)?|border(?:-(?:top|right|bottom|left))?(?:-color)?|fill|stroke|outline-color|accent-color|box-shadow):\s*([^;]+);/)

          expect(declarations).not_to be_empty
          declarations.each do |property, value|
            expect(value).to match(/\$color-[a-z-]+/), "#{property}: #{value} does not use a colour token"
          end
        end

        it "only uses tokens that _tokens.scss defines" do
          defined = tokens.scan(/^\$([a-z0-9-]+):/).flatten
          used = code.scan(/\$([a-z0-9-]+)/).flatten.uniq

          expect(used - defined).to be_empty
        end

        it "defines every colour token as a Design System variable with the Figma value as fallback" do
          definitions = tokens.scan(/^\$(color-[a-z-]+):\s*([^;]+);/)

          expect(definitions).not_to be_empty
          definitions.each do |name, value|
            expect(value).to match(/\Avar\(--(?:color-color-[a-z-]+|secondary), #\h{6}\)\z/), "$#{name}: #{value}"
          end
        end
      end
    end
  end
end
```

`spec/forms/decidim/elections/vocdoni/admin_forms/security_form_spec.rb` (edit):
old:
```ruby
          describe "from the submitted page" do
```
new:
```ruby
          describe ".level_for" do
            it "is basic for an election that has not opted in" do
              expect(described_class.level_for(election)).to eq("basic")
            end

            it "is strong for a secret vote without a code" do
              Vocdoni::Process.create!(election:, state: "pending")

              expect(described_class.level_for(election.reload)).to eq("strong")
            end

            it "is strongest for a secret vote with a code" do
              Vocdoni::Process.create!(election:, state: "pending",
                                       metadata: { "settings" => { "twofa_fields" => %w(phone) } })

              expect(described_class.level_for(election.reload)).to eq("strongest")
            end
          end

          describe "from the submitted page" do
```

Run:
```
bundle exec rspec spec/requests/decidim/elections/vocdoni/admin/security_spec.rb
bundle exec rspec spec/requests/decidim/elections/vocdoni/admin/dashboard_spec.rb
bundle exec rspec spec/lib/decidim/elections/vocdoni/dashboard_override_spec.rb
bundle exec rspec spec/lib/decidim/elections/vocdoni/security_stylesheet_spec.rb
bundle exec rspec spec/forms/decidim/elections/vocdoni/admin_forms/security_form_spec.rb
```
Expected (one line per command, verified against `b85f88b`):
```
11 examples, 5 failures      # the 5 admin examples except "keeps the radios…"; AC2 denials already pass (404 / sign-in redirect)
5 examples, 5 failures       # no `.vocdoni-security-summary` on the Dashboard
6 examples, 5 failures       # only "is synced with the installed upstream dashboard" passes
5 examples, 4 failures       # only "writes no raw colour" passes; `_tokens.scss` does not exist
10 examples, 3 failures      # the three `.level_for` examples (NoMethodError)
```
If a request spec fails with anything other than the assertion (500, missing
factory, routing error), stop and report: the expectations below depend on it.

`bundle exec rubocop spec/requests spec/lib spec/forms` → `no offenses detected`.

Step 2: commit (red on purpose; tasks 2–5 turn these green)
```
git add spec/requests/decidim/elections/vocdoni/admin/security_spec.rb spec/requests/decidim/elections/vocdoni/admin/dashboard_spec.rb spec/lib/decidim/elections/vocdoni/dashboard_override_spec.rb spec/lib/decidim/elections/vocdoni/security_stylesheet_spec.rb
git commit -m "test(security): specify the redesigned security tab and dashboard card" -- spec/requests/decidim/elections/vocdoni/admin/security_spec.rb spec/requests/decidim/elections/vocdoni/admin/dashboard_spec.rb spec/lib/decidim/elections/vocdoni/dashboard_override_spec.rb spec/lib/decidim/elections/vocdoni/security_stylesheet_spec.rb spec/forms/decidim/elections/vocdoni/admin_forms/security_form_spec.rb
```

Interfaces this task provides to later tasks (the markup contract the specs
read; keep these names exactly):
- Security tab: one `.vocdoni-security__card` containing
  `details.vocdoni-security__section[open] > summary.vocdoni-security__summary`
  with `h2#security-choice-title`; `fieldset#js-security-choice` with two
  `[data-security-choice-card="simple|secure"]`, each with `ul.list-disc` (4
  `li`, no `svg`) and `.vocdoni-choice__footer` containing "Best for:";
  `#security-choice-badge` as a direct child of the secure card, without the
  `label` class; `[data-security-good-to-know]` inside the choice fieldset;
  `fieldset#js-security-two-factor` carrying `hidden` and `disabled` when
  `enable_vocdoni` is false; radios `#security_choice_{simple,secure}` with
  `name="security[enable_vocdoni]"`, values `"false"`/`"true"`, secure
  `aria-describedby="security-choice-badge security-choice-secure-description"`;
  `h1.item_show__header-title` "Edit election"; no `vocdoni-why`, no
  `#js-security-summary`.
- Dashboard: `.item__edit-form > .vocdoni-security-summary` (last child when
  published, directly before `.form__wrapper` (Main) when not), with
  `svg.vocdoni-security-summary__icon` in `.card-divider .card-title` and
  `.vocdoni-security-summary__sentence[data-security-level]`.
- Override: `app/views/overrides/decidim/elections/admin/elections/dashboard.html.erb`,
  header comment closed by a line that is exactly `%>`, two added lines equal
  to `    <%= render partial: "decidim/elections/vocdoni/admin/dashboard/security" %>`,
  and `app/views/overrides` first on
  `Decidim::Elections::Admin::ElectionsController.view_paths` only.
- `Decidim::Elections::Vocdoni::AdminForms::SecurityForm.level_for(election) → "basic" | "strong" | "strongest"`.
- Stylesheet: `_tokens.scss` defines every `$color-*` as
  `var(--color-color-…|--secondary, #rrggbb)`; `security.scss` uses only
  `$…` tokens for colour.

### Task 2: Tokens and stylesheet
Model: sonnet   Repo: /Users/ferran/Repos/decidim/decidim-secure_elections
Files:
- `app/packs/stylesheets/decidim/elections/vocdoni/admin/_tokens.scss` (new)
- `app/packs/stylesheets/decidim/elections/vocdoni/admin/security.scss` (full rewrite)

Goal: R1, R7–R9 styling and AC5: one token map with Design System variables
and Figma fallbacks; the tab and Dashboard card styled from it; contrast pairs
recorded as comments (AC7, second half).

Notes that are load-bearing:
- The `@use` must go through the load path
  (`"stylesheets/decidim/elections/vocdoni/admin/tokens"`). Decidim's Sass
  loader (`packages/webpacker/src/loaders/decidim-sass-loader.js`) calls
  `sass.compileString` without the file URL, so a relative `@use "tokens"`
  fails the webpack build with "Can't find stylesheet to import" while every
  spec stays green. This was hit and fixed during drafting.
- Borders are plain `border: 1px solid $token` declarations (not `@apply
  border`), so the colour spec sees them and nothing depends on Tailwind's
  preflight border defaults.
- No white token: the cards sit on upstream's white content area; README has no
  Design System variable for white.

Step 1: the failing test exists (Task 1)
Run: `bundle exec rspec spec/lib/decidim/elections/vocdoni/security_stylesheet_spec.rb`
Expected: `5 examples, 4 failures`

Step 2: implement

`app/packs/stylesheets/decidim/elections/vocdoni/admin/_tokens.scss` (full content):
```scss
// Decidim Design System tokens used by this module's admin screens.
//
// Decidim is landing the Design System variables as CSS custom properties in
// decidim/decidim#17722 (`decidim-core/app/packs/stylesheets/decidim/tokens/`,
// generated from Figma). Until that PR is in the Decidim version this module
// runs on, the variables are undefined, so every token carries the Figma value
// as its fallback: the screens render the same before and after it lands.
// Names, values and uses: `docs/design/security-tab/README.md`.
//
// Only colour and type live here. Spacing and radii are the Tailwind
// utilities whose values already equal the Design System measures (`gap-2`
// 8px, `p-4` 16px, `gap-5` 20px, `gap-6` 24px, `rounded` 4px, `rounded-lg`
// 8px), so nothing changes when the PR maps the measures onto that scale.
//
// Contrast of every pair these tokens form (WCAG 2.1 AA, measured; text needs
// 4.5:1, non-text 3:1):
//   #525252 on #fafafa  7.3:1   footer band text, helper text
//   #525252 on #ffffff  7.8:1   points, notes
//   #303030 on #e8eff9 10.9:1   "Best for:" on the selected band
//   #525252 on #e8eff9  6.6:1   selected band text
//   #155abf on #e8eff9  5.4:1   "Recommended" pill
//   #155abf on #ffffff  6.3:1   section title
//   #6b7280 on #ffffff  4.0:1   radio border (native control, non-text)
// Do not pair these tokens any other way without measuring first.

// Text
$color-text-neutral-dark: var(--color-color-text-neutral-dark, #303030);
$color-text-neutral-light: var(--color-color-text-neutral-light, #525252);

// Backgrounds
$color-bg-neutral-dark: var(--color-color-bg-neutral-dark, #fafafa);
$color-bg-info-light: var(--color-color-bg-info-light, #e8eff9);

// Borders
$color-border-neutral-light: var(--color-color-border-neutral-light, #e7e7e7);
$color-border-secondary: var(--color-color-border-secondary, #155abf);

// Icons
$color-icon-neutral-light: var(--color-color-icon-neutral-light, #525252);
$color-icon-secondary: var(--color-color-icon-secondary, #155abf);

// `Secondary/Blue`. The PR keeps Decidim's `--secondary` as an alias, and the
// admin already defines it (`decidim/admin/application.scss`).
$color-secondary: var(--secondary, #155abf);

// Type: `typography/fontSize/*` and `typography/lineHeight/*`.
$font-size-sm: var(--measure-font-size-typography-fontsize-sm, 14px);
$line-height-sm: var(--measure-line-height-typography-lineheight-sm, 21px);
$font-size-md: var(--measure-font-size-typography-fontsize-md, 16px);
$line-height-md: var(--measure-line-height-typography-lineheight-md, 24px);
```

`app/packs/stylesheets/decidim/elections/vocdoni/admin/security.scss` (full content):
```scss
// The Security tab (`admin/security/show.html.erb`) and the Dashboard card
// (`admin/dashboard/_security.html.erb`), after the Decidim 2026 design:
// `docs/design/security-tab/README.md`.
//
// Every colour and type size is a token from `_tokens.scss` (a Design System
// variable with the Figma value as fallback; the contrast of each pair is
// recorded there). Spacing and radii are Tailwind utilities carrying the same
// measures. `spec/lib/decidim/elections/vocdoni/security_stylesheet_spec.rb`
// fails on a Tailwind colour utility or a raw colour in this file.
//
// The tab is scoped under `.vocdoni-security`, which sits on the same element
// as upstream's `.item__edit-form`. That matters for labels:
// `.item__edit-form label` makes every label small and grey, and a scoped
// class selector (two classes) is what outranks it without `!important`.

// Decidim's Sass loader compiles from a string, so imports resolve through
// the registered `app/packs` load path, never relative to this file.
@use "stylesheets/decidim/elections/vocdoni/admin/tokens" as *;

.vocdoni-security {
  [hidden] {
    display: none !important;
  }

  .vocdoni-security__fieldset {
    @apply m-0 p-0 border-0 min-w-0;
  }
}

// The one outer card, its disclosure header and the lead.
//
// The header is a native `<details open>`/`<summary>`, so the chevron is a
// working disclosure without JavaScript. Open, the chevron points down (as in
// Figma); closed, it points right.
.vocdoni-security {
  .vocdoni-security__card {
    @apply mb-6 p-4 rounded-lg;

    border: 1px solid $color-border-neutral-light;
    color: $color-text-neutral-dark;
  }

  .vocdoni-security__summary {
    @apply flex items-center gap-2 pb-2 list-none cursor-pointer;

    border-bottom: 1px solid $color-border-neutral-light;

    &::-webkit-details-marker {
      display: none;
    }

    &:focus-visible {
      @apply outline outline-2 outline-offset-2;

      outline-color: $color-secondary;
    }
  }

  .vocdoni-security__chevron {
    @apply w-6 h-6 shrink-0 transition-transform;

    fill: $color-icon-secondary;
  }

  .vocdoni-security__section:not([open]) .vocdoni-security__chevron {
    @apply -rotate-90;
  }

  .vocdoni-security__legend {
    @apply m-0 font-semibold;

    font-size: $font-size-md;
    line-height: $line-height-md;
    color: $color-secondary;
  }

  .vocdoni-security__content {
    @apply flex flex-col gap-6 pt-6;
  }

  .vocdoni-security__lead {
    @apply m-0;

    font-size: $font-size-md;
    line-height: $line-height-md;
    color: $color-text-neutral-dark;
  }

  // "Good to know" and the closing note of the one-time code: a plain row,
  // no box and no background.
  .vocdoni-security__note {
    @apply flex items-start gap-2 m-0;

    font-size: $font-size-sm;
    line-height: $line-height-sm;
    color: $color-text-neutral-light;

    svg {
      @apply w-5 h-5 shrink-0;

      fill: $color-icon-neutral-light;
    }

    strong {
      @apply font-semibold;
    }
  }
}

// Vote-type cards.
//
// The card is a plain block; only its title is the radio's <label>.
// `security.js` makes the rest of the card select the option, without an
// overlay that would stop admins selecting the text.
.vocdoni-security {
  .vocdoni-security__choice {
    @apply flex flex-col gap-6;
  }

  // Two columns only from `xl`: next to Decidim's two admin sidebars the
  // form is under 650px wide below that, too narrow for side-by-side cards.
  // Grid rows stretch, so both cards are as tall as the tallest.
  .vocdoni-choices {
    @apply grid gap-5 xl:grid-cols-2;
  }

  // The selected border is 2 px: the 1 px border plus a 1 px ring outside
  // it, so selecting a card does not move its content.
  .vocdoni-choice {
    @apply relative flex flex-col gap-4 pt-4 rounded-lg cursor-pointer transition-colors;

    border: 1px solid $color-border-neutral-light;

    &:hover,
    &.is-selected,
    &:has(.vocdoni-choice__input:checked) {
      border-color: $color-border-secondary;
    }

    &.is-selected,
    &:has(.vocdoni-choice__input:checked) {
      box-shadow: 0 0 0 1px $color-border-secondary;

      .vocdoni-choice__footer {
        background-color: $color-bg-info-light;
      }
    }

    &:has(.vocdoni-choice__input:focus-visible) {
      @apply outline outline-2 outline-offset-4;

      outline-color: $color-secondary;
    }
  }

  .vocdoni-choice__header {
    @apply flex items-center gap-2 px-4;
  }

  .vocdoni-choice__input {
    @apply w-4 h-4 m-0 shrink-0 cursor-pointer;

    accent-color: $color-secondary;
  }

  .vocdoni-choice__title {
    @apply m-0 font-semibold cursor-pointer;

    font-size: $font-size-md;
    line-height: $line-height-md;
    color: $color-text-neutral-dark;
  }

  // "Recommended for binding decisions" sits on the secure card's top edge,
  // half above it, so both cards keep their headers aligned.
  .vocdoni-choice__badge {
    @apply absolute -top-3 right-4 z-[1] px-2 py-0.5 rounded font-semibold;

    font-size: $font-size-sm;
    line-height: $line-height-sm;
    color: $color-secondary;
    background-color: $color-bg-info-light;
  }

  .vocdoni-choice__body {
    @apply flex flex-col flex-1 gap-4;
  }

  .vocdoni-choice__points {
    @apply my-0 mx-4 ps-[21px] list-disc list-outside;

    font-size: $font-size-sm;
    line-height: $line-height-sm;
    color: $color-text-neutral-light;

    li {
      @apply m-0;
    }
  }

  // The footer band is pushed to the bottom of the card; its corners follow
  // the card's 8 px radius inside the 1 px border.
  .vocdoni-choice__footer {
    @apply flex flex-col mt-auto px-4 pt-2 pb-4 rounded-b-[7px];

    font-size: $font-size-sm;
    line-height: $line-height-sm;
    color: $color-text-neutral-light;
    background-color: $color-bg-neutral-dark;

    p {
      @apply m-0;
    }

    strong {
      @apply font-normal;

      color: $color-text-neutral-dark;
    }

    a {
      @apply underline;

      color: $color-secondary;
    }
  }
}

// One-time code block: inside the same card, shown only for the secret vote.
.vocdoni-security {
  .vocdoni-two-factor {
    @apply flex flex-col gap-6;
  }

  .vocdoni-two-factor__header {
    @apply flex flex-col gap-4;
  }

  .vocdoni-two-factor__title {
    @apply m-0 font-semibold;

    font-size: $font-size-md;
    line-height: $line-height-md;
    color: $color-text-neutral-dark;
  }

  .vocdoni-two-factor__lead {
    @apply m-0;

    font-size: $font-size-md;
    line-height: $line-height-md;
    color: $color-text-neutral-dark;
  }

  .vocdoni-two-factor__option {
    @apply flex flex-col gap-2;
  }

  .vocdoni-two-factor__control {
    @apply flex items-center gap-2;

    input[type="checkbox"] {
      @apply w-4 h-4 m-0 shrink-0 rounded cursor-pointer;

      accent-color: $color-secondary;
    }
  }

  // Figma 16/22 and 14/18: no Design System line-height token for either.
  .vocdoni-two-factor__label {
    @apply m-0 cursor-pointer;

    font-size: $font-size-md;
    line-height: 22px;
    color: $color-text-neutral-dark;
  }

  .vocdoni-two-factor__help {
    @apply m-0;

    font-size: $font-size-sm;
    line-height: 18px;
    color: $color-text-neutral-light;
  }
}

// Dashboard card. The chrome (`card`, `card-divider`, `card-title`) is
// upstream's, as on its sibling cards; only the icon and the sentence are
// styled here. The icon selector has to outrank upstream's
// `.item__edit-form .card-divider *:not(.button--title) > svg` (24 px).
.vocdoni-security-summary {
  @apply my-6 pb-4;

  .card-divider .card-title {
    @apply gap-2;
  }

  .card-divider .card-title > svg.vocdoni-security-summary__icon {
    @apply w-5 h-5 shrink-0;

    fill: $color-icon-secondary;
  }

  // Figma 14/16: no Design System line-height token for 16.
  .vocdoni-security-summary__sentence {
    @apply m-0;

    font-size: $font-size-sm;
    line-height: 16px;
    color: $color-text-neutral-light;
  }
}

@media (prefers-reduced-motion: reduce) {
  .vocdoni-security {
    .vocdoni-choice,
    .vocdoni-security__chevron {
      transition: none;
    }
  }
}
```

Run:
```
bundle exec rspec spec/lib/decidim/elections/vocdoni/security_stylesheet_spec.rb
npm run stylelint
grep -E "webpack [0-9.]+ compiled" spec/decidim_dummy_app/log/test.log | tail -1
grep -c "color-color-bg-info-light" spec/decidim_dummy_app/public/packs-test/css/decidim_elections_vocdoni_admin.css
```
Expected:
```
5 examples, 0 failures
(stylelint prints nothing and exits 0)
webpack 5.109.2 compiled with 4 warnings in … ms        # must not say "errors"; the 4 warnings are upstream's oversized-asset warnings
2
```
Every spec run rebuilds the packs first when `app/packs` changed (decidim-dev's
`Shakapacker.compile` in `before(:all)`), so the first command above is what
produced the build line. If it says "errors", read the `ERROR in` block above it in
`spec/decidim_dummy_app/log/test.log` and fix the SCSS before committing.

Step 3: commit
```
git add app/packs/stylesheets/decidim/elections/vocdoni/admin/_tokens.scss
git commit -m "feat(security): style the security tab with design system tokens" -- app/packs/stylesheets/decidim/elections/vocdoni/admin/_tokens.scss app/packs/stylesheets/decidim/elections/vocdoni/admin/security.scss
```

Interfaces this task provides to later tasks: the classes Task 3 and Task 5
render (`vocdoni-security__card`, `__section`, `__summary`, `__chevron`,
`__legend`, `__content`, `__lead`, `__note`, `__choice`, `__fieldset`;
`vocdoni-choices`, `vocdoni-choice` (+ `is-selected`), `__header`, `__input`,
`__title`, `__badge`, `__body`, `__points`, `__footer`; `vocdoni-two-factor`,
`__header`, `__title`, `__lead`, `__option`, `__control`, `__label`, `__help`;
`vocdoni-security-summary`, `__icon`, `__sentence`). Tokens: `$color-*`,
`$font-size-{sm,md}`, `$line-height-{sm,md}` in `_tokens.scss`.

### Task 3: Security tab views and copy
Model: sonnet   Repo: /Users/ferran/Repos/decidim/decidim-secure_elections
Files:
- `app/views/decidim/elections/vocdoni/admin/security/show.html.erb` (full rewrite)
- `app/views/decidim/elections/vocdoni/admin/security/_choice.html.erb` (full rewrite)
- `app/views/decidim/elections/vocdoni/admin/security/_two_factor.html.erb` (full rewrite)
- `app/views/decidim/elections/vocdoni/admin/security/_why_it_matters.html.erb` (delete)
- `app/views/decidim/elections/vocdoni/admin/security/_summary.html.erb` (delete)
- `config/locales/security.en.yml` (full rewrite)

Goal: AC1 and R4–R8, R10: one outer card with a `<details open>` header, two
option cards with plain points and a footer band, the positioned pill, the
inline "Good to know" row and the one-time-code block (server-rendered
`hidden` + `disabled` for a simple vote); drop "Why it matters" and the
summary line with their keys.

Notes:
- `h1` uses upstream's `decidim.elections.admin.elections.edit.title` (R6);
  `add_decidim_page_title(t(".title"))` keeps "Security" as the browser title.
- Keys are written with a literal `scope: "…"` string, not a `scope` local:
  i18n-tasks cannot resolve a local variable and reported every Security key
  as unused before this change (Task 6 relies on this).
- The `<h2>` sits inside `<summary>` (HTML allows one heading there); the
  one-time-code heading is `<h3>` under it. The choice fieldset stays
  `aria-labelledby="security-choice-title"` (now the `h2`).
- Removed keys (R5): `show.why.*`, `show.summary.levels.*`, `show.summary.title`
  (only the removed summary line used it; the Dashboard card gets its own
  title key in Task 5), `show.choice.{simple,secure}.summary`,
  `show.two_factor.simple_note`, `show.choice.selected`. Kept:
  `show.summary.sentences.*` (Dashboard card), every other key.
- `i18n-tasks normalize` is not run: on this repo it rewrites
  `config/locales/en.vote.yml` (forbidden by Global Constraints), strips every
  comment from `security.en.yml` and re-wraps the strings; the file already
  fails `check-normalized` on `b85f88b` for the same reasons. The file is
  edited by hand in its existing style instead (flagged to the owner).

Step 1: the failing test exists (Task 1)
Run: `bundle exec rspec spec/requests/decidim/elections/vocdoni/admin/security_spec.rb`
Expected: `11 examples, 5 failures`

Step 2: implement

`app/views/decidim/elections/vocdoni/admin/security/show.html.erb` (full content):
```erb
<%#
  Security tab, shown on every election between Census and Dashboard.

  One card, as in the Decidim 2026 design (docs/design/security-tab/README.md):
  how the vote runs — a simple Decidim vote or a secret, verifiable one on
  Vocdoni (`enable_vocdoni`; opting in creates the `Vocdoni::Process`
  sidecar) — and, for the secret vote only, the one-time code sent to voters
  (`twoFaFields`). The resulting configuration is summarised on the
  Dashboard (`admin/dashboard/_security`), not here.

  The section header is a native `<details open>`, so it opens and closes
  without JavaScript. The server renders every state; `security.js` only
  keeps the page in step with unsaved changes.
%>
<% add_decidim_page_title(t(".title")) %>
<% append_javascript_pack_tag "decidim_elections_vocdoni_admin" %>
<% append_stylesheet_pack_tag "decidim_elections_vocdoni_admin", media: "all" %>

<div class="item_show__header border-none">
  <%# The same title as upstream's Main, Questions, Census and Dashboard
      tabs; the browser title above keeps naming this tab. %>
  <h1 class="item_show__header-title"><%= t("decidim.elections.admin.elections.edit.title") %></h1>
</div>

<%# Upstream's tabs menu (admin_elections_menu), where this engine
    injects the Security item. %>
<%= render "decidim/elections/admin/elections/tabs_menu" %>

<div class="item__edit-form vocdoni-security 2xl:mr-80">
  <%# `request.path` is the URL bound to both #show and #update
      (`resource :security`). A string rather than the named helper because
      this view renders inside upstream's admin engine, whose url_helpers
      only learn about the injected route through method_missing. %>
  <%= decidim_form_for(@form,
                       url: request.path,
                       method: :put,
                       html: { id: "security-form", class: "form-defaults form" }) do |f| %>
    <div class="vocdoni-security__card">
      <details class="vocdoni-security__section" open>
        <summary class="vocdoni-security__summary">
          <%= icon "arrow-down-s-line", class: "vocdoni-security__chevron" %>
          <h2 class="vocdoni-security__legend" id="security-choice-title">
            <%= t("legend", scope: "decidim.elections.vocdoni.admin.security.show.choice") %>
          </h2>
        </summary>

        <div class="vocdoni-security__content">
          <%= render "decidim/elections/vocdoni/admin/security/choice", f: %>
          <%= render "decidim/elections/vocdoni/admin/security/two_factor", f: %>
        </div>
      </details>
    </div>

    <div class="item__edit-sticky">
      <div class="item__edit-sticky-container">
        <%# Upstream's own label ("Save and continue"), as on Questions and
            Census; the controller continues the wizard onto Dashboard. %>
        <%= f.submit t("save", scope: "decidim.elections.admin.elections.form"),
                     id: "js-security-submit",
                     class: "button button__sm button__secondary" %>
      </div>
    </div>
  <% end %>
</div>
```

`app/views/decidim/elections/vocdoni/admin/security/_choice.html.erb` (full content):
```erb
<%#
  How the vote runs: the lead, two option cards and the "Good to know" row.

  Each option is a card whose radio is labelled by the card title only; the
  points and the footer band describe it (`aria-describedby`), so a screen
  reader announces "Simple vote, radio" rather than the whole card. The
  "Recommended" pill on the secure card is part of its description too.
  `security.js` makes the rest of the card clickable; the text stays
  selectable, as admins copy these points into board papers.

  Both radios write `enable_vocdoni` ("false" / "true"); `data-security-choice`
  names the card for `security.js`.

  Keys are spelled out with a literal `scope:` so that i18n-tasks sees them.
%>
<%
  points = {
    "simple" => %w(stored readable unverifiable editable),
    "secure" => %w(anonymous tamper minimal locked)
  }
%>
<fieldset id="js-security-choice"
          class="vocdoni-security__fieldset vocdoni-security__choice"
          aria-labelledby="security-choice-title"
          aria-describedby="security-choice-lead">
  <p class="vocdoni-security__lead" id="security-choice-lead"><%= t("lead", scope: "decidim.elections.vocdoni.admin.security.show.choice") %></p>

  <div class="vocdoni-choices">
    <% points.each do |value, keys| %>
      <% selected = @form.choice == value %>
      <div class="vocdoni-choice<%= " is-selected" if selected %>" data-security-choice-card="<%= value %>">
        <% if value == "secure" %>
          <span class="vocdoni-choice__badge" id="security-choice-badge"><%= t("recommended", scope: "decidim.elections.vocdoni.admin.security.show.choice") %></span>
        <% end %>

        <div class="vocdoni-choice__header">
          <%= f.radio_button :enable_vocdoni, (value == "secure").to_s,
                             label: false,
                             id: "security_choice_#{value}",
                             class: "vocdoni-choice__input",
                             aria: {
                               describedby: [("security-choice-badge" if value == "secure"), "security-choice-#{value}-description"].compact.join(" ")
                             },
                             data: { security_choice: value } %>
          <label for="security_choice_<%= value %>" class="vocdoni-choice__title">
            <%= t("#{value}.title", scope: "decidim.elections.vocdoni.admin.security.show.choice") %>
          </label>
        </div>

        <div class="vocdoni-choice__body" id="security-choice-<%= value %>-description">
          <ul class="vocdoni-choice__points list-disc">
            <% keys.each do |key| %>
              <li><%= t("#{value}.points.#{key}", scope: "decidim.elections.vocdoni.admin.security.show.choice") %></li>
            <% end %>
          </ul>

          <div class="vocdoni-choice__footer" data-security-choice-footer>
            <p>
              <strong><%= t("best_for", scope: "decidim.elections.vocdoni.admin.security.show.choice") %></strong>
              <%= t("#{value}.best_for", scope: "decidim.elections.vocdoni.admin.security.show.choice") %>
            </p>
            <% if value == "secure" %>
              <% guide_url = t("secure.guide_url", scope: "decidim.elections.vocdoni.admin.security.show.choice") %>
              <p>
                <%= t("secure.powered_by", scope: "decidim.elections.vocdoni.admin.security.show.choice") %>
                <% if guide_url.present? %>
                  <%= link_to t("secure.guide_link", scope: "decidim.elections.vocdoni.admin.security.show.choice"), guide_url, target: "_blank", rel: "noopener noreferrer" %>
                <% end %>
              </p>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
  </div>

  <p class="vocdoni-security__note" data-security-good-to-know>
    <%= icon "information-line" %>
    <span><%= t("good_to_know_html", scope: "decidim.elections.vocdoni.admin.security.show.choice") %></span>
  </p>
</fieldset>
```

`app/views/decidim/elections/vocdoni/admin/security/_two_factor.html.erb` (full content):
```erb
<%#
  The one-time code (`twoFaFields`), inside the same card as the vote type.

  Only meaningful for a secret vote, so the whole block is rendered `hidden`
  and its fieldset `disabled` (nothing in it is submitted) while the simple
  vote is selected; `security.js` flips both as the admin changes the vote
  type, without saving. Email and SMS are independent; with both on, the
  voter picks the channel when the code is requested.
%>
<% enabled = @form.enable_vocdoni %>
<fieldset id="js-security-two-factor"
          class="vocdoni-security__fieldset vocdoni-two-factor"
          aria-labelledby="security-two-factor-title"
          aria-describedby="security-two-factor-lead"
          <%= "hidden" unless enabled %>
          <%= "disabled" unless enabled %>>
  <div class="vocdoni-two-factor__header">
    <h3 class="vocdoni-two-factor__title" id="security-two-factor-title"><%= t("legend", scope: "decidim.elections.vocdoni.admin.security.show.two_factor") %></h3>
    <p class="vocdoni-two-factor__lead" id="security-two-factor-lead"><%= t("lead", scope: "decidim.elections.vocdoni.admin.security.show.two_factor") %></p>
  </div>

  <div class="vocdoni-two-factor__option">
    <div class="vocdoni-two-factor__control">
      <%= f.check_box :email,
                      label: false,
                      id: "security_email",
                      aria: { describedby: "security-email-help" },
                      data: { security_code: true } %>
      <label for="security_email" class="vocdoni-two-factor__label"><%= t("email.label", scope: "decidim.elections.vocdoni.admin.security.show.two_factor") %></label>
    </div>
    <p class="vocdoni-two-factor__help" id="security-email-help"><%= t("email.help", scope: "decidim.elections.vocdoni.admin.security.show.two_factor") %></p>
  </div>

  <div class="vocdoni-two-factor__option">
    <div class="vocdoni-two-factor__control">
      <%= f.check_box :sms,
                      label: false,
                      id: "security_sms",
                      aria: { describedby: "security-sms-help" },
                      data: { security_code: true } %>
      <label for="security_sms" class="vocdoni-two-factor__label"><%= t("sms.label", scope: "decidim.elections.vocdoni.admin.security.show.two_factor") %></label>
    </div>
    <p class="vocdoni-two-factor__help" id="security-sms-help"><%= t("sms.help", scope: "decidim.elections.vocdoni.admin.security.show.two_factor") %></p>
  </div>

  <p class="vocdoni-security__note">
    <%= icon "information-line" %>
    <span><%= t("both_note", scope: "decidim.elections.vocdoni.admin.security.show.two_factor") %></span>
  </p>
</fieldset>
```

Delete the two partials:
```
git rm app/views/decidim/elections/vocdoni/admin/security/_why_it_matters.html.erb app/views/decidim/elections/vocdoni/admin/security/_summary.html.erb
```

`config/locales/security.en.yml` (full content):
```yaml
en:
  decidim:
    admin:
      menu:
        # Injected into upstream's `admin_elections_menu` by this engine.
        # Appears on every election so an admin can discover the Vocdoni
        # opt-in on the Security tab.
        elections_menu:
          security: "Security"
    elections:
      vocdoni:
        admin:
          # The Security tab. Written for the person running the vote, not for
          # engineers: no "blockchain", "CSP", "OTP" or "manifest". The two
          # vote types are "Simple vote" (any standard Decidim census) and
          # "Secret, verifiable vote" (`enable_vocdoni`, the Vocdoni opt-in).
          security:
            show:
              title: "Security"
              choice:
                legend: "How do you want to run this vote?"
                lead: "This choice decides who can read the ballots and whether the count can be checked by someone other than you."
                recommended: "Recommended for binding decisions"
                best_for: "Best for:"
                simple:
                  title: "Simple vote"
                  points:
                    stored: "Ballots are stored in this platform's database."
                    readable: "Platform administrators can technically read them."
                    unverifiable: "Results are computed by this server; nobody outside can check them."
                    editable: "Can be edited until the vote starts."
                  best_for: "Informal polls, quick consultations, decisions nobody is likely to contest."
                secure:
                  title: "Secret, verifiable vote"
                  points:
                    anonymous: "Nobody — not even administrators — can link a ballot to a voter."
                    tamper: "Any tampering is detectable: each voter gets a receipt to check on a public explorer, and the results export links there too."
                    minimal: "Only the details needed to check who may vote are used; ballots hold no personal data."
                    locked: "Locked once published — that is what makes it trustworthy."
                  best_for: "Elections of officers, statutory votes, budgets — anything that must stand up to challenge."
                  powered_by: "Powered by the Vocdoni voting protocol."
                  # Leave empty until the admin guide exists: the link is only
                  # rendered when this has a value.
                  guide_url: ""
                  guide_link: "Read the full guide"
                good_to_know_html: "<strong>Good to know:</strong> you can change this choice until the election is published. Voters won't notice any difference, except the one-time code if you enable it."
              two_factor:
                legend: "Confirm voters' identity with a one-time code"
                lead: "Each voter receives a one-time code when they open the ballot and types it in before voting. It stops someone voting on behalf of another person and makes the result harder to dispute."
                email:
                  label: "Email code"
                  help: "The code goes to the email address each participant registered with."
                sms:
                  label: "SMS code"
                  help: "The code goes by text message, so every voter needs a phone number registered with the voting service."
                both_note: "If both are on, each voter chooses how to receive the code."
              # One sentence per level (`SecurityForm::LEVELS`), shown on the
              # Dashboard card ("Your security configuration").
              summary:
                sentences:
                  basic: "Ballots are kept on this platform. Suitable for informal consultations."
                  strong: "Anonymous ballots, result checkable by anyone."
                  strongest: "Anonymous ballots, result checkable by anyone. Voters confirm their identity with a one-time code."
            update:
              success: "Security settings updated."
              invalid: "Security settings could not be saved. Please review the errors below."
        booth:
          launcher:
            help_html: "Your vote is cast using Vocdoni’s secure technology, guaranteeing anonymity and verifiability."
            enter: "Open the voting booth"
            not_ready: "This election is not yet ready to accept votes on the blockchain. Please try again in a few moments."
```

Run:
```
bundle exec rspec spec/requests/decidim/elections/vocdoni/admin/security_spec.rb
ruby -ryaml -e 'YAML.load_file("config/locales/security.en.yml"); puts "ok"'
grep -rn "why_it_matters\|security/summary\|simple_note\|levels\." app/views config/locales/security.en.yml
```
Expected:
```
11 examples, 0 failures
ok
(no output)
```

Step 3: commit
```
git commit -m "feat(security): rebuild the security tab on the decidim 2026 design" -- app/views/decidim/elections/vocdoni/admin/security/show.html.erb app/views/decidim/elections/vocdoni/admin/security/_choice.html.erb app/views/decidim/elections/vocdoni/admin/security/_two_factor.html.erb app/views/decidim/elections/vocdoni/admin/security/_why_it_matters.html.erb app/views/decidim/elections/vocdoni/admin/security/_summary.html.erb config/locales/security.en.yml
```

Interfaces this task provides to later tasks: the DOM read by `security.js`
(`#js-security-choice`, `[data-security-choice]`, `[data-security-choice-card]`,
`#js-security-two-factor`, `[data-security-code]`; no `[data-two-factor-note]`,
no `#js-security-summary`); `security.en.yml` without `show.summary.title`,
with `show.summary.sentences.{basic,strong,strongest}`.

### Task 4: Security tab script
Model: sonnet   Repo: /Users/ferran/Repos/decidim/decidim-secure_elections
Files:
- `app/packs/src/decidim/elections/vocdoni/admin/security.test.js` (new)
- `app/packs/src/decidim/elections/vocdoni/admin/security.js` (full rewrite)

Goal: R4, R10 and the Review Focus on `security.js`: remove the summary sync
(and `securityLevel`, which only fed it), keep the card selection and the
fieldset toggle, add the `hidden` toggle, and prove both work without a
summary element. Selectors are unchanged ids/`data-` attributes. The test file
is excluded from the gem by the gemspec (`.test.js`).

Step 1: write the failing test

`app/packs/src/decidim/elections/vocdoni/admin/security.test.js` (full content):
```js
/**
 * The Security tab's progressive enhancement against the markup the server
 * renders (`admin/security/_choice` and `_two_factor`), reduced to the
 * selectors `security.js` reads. There is no summary element any more: the
 * toggles must work without it.
 */
import setupSecurity from "src/decidim/elections/vocdoni/admin/security";

// What the server renders for each saved choice.
const SAVED = {
  simple: { simple: "checked", secure: "", block: "hidden disabled" },
  secure: { simple: "", secure: "checked", block: "" }
};

const render = (saved) => {
  const state = SAVED[saved];
  document.body.innerHTML = `
    <fieldset id="js-security-choice">
      <div data-security-choice-card="simple">
        <input type="radio" name="security[enable_vocdoni]" value="false" data-security-choice="simple" ${state.simple}>
        <label>Simple vote</label>
        <ul><li data-testid="simple-point">Ballots are stored in this platform's database.</li></ul>
      </div>
      <div data-security-choice-card="secure">
        <input type="radio" name="security[enable_vocdoni]" value="true" data-security-choice="secure" ${state.secure}>
        <label>Secret, verifiable vote</label>
        <ul><li data-testid="secure-point">Nobody can link a ballot to a voter.</li></ul>
      </div>
    </fieldset>
    <fieldset id="js-security-two-factor" ${state.block}>
      <input type="checkbox" name="security[email]" data-security-code>
    </fieldset>
  `;
  setupSecurity();
};

const card = (value) => document.querySelector(`[data-security-choice-card="${value}"]`);
const twoFactor = () => document.getElementById("js-security-two-factor");

describe("Security tab", () => {
  afterEach(() => {
    document.body.innerHTML = "";
  });

  it("shows and enables the one-time code block when the secret vote is picked", () => {
    render("simple");

    document.querySelector("[data-testid='secure-point']").click();

    expect(card("secure").classList.contains("is-selected")).toBe(true);
    expect(card("simple").classList.contains("is-selected")).toBe(false);
    expect(twoFactor().hidden).toBe(false);
    expect(twoFactor().disabled).toBe(false);
  });

  it("hides and disables the one-time code block when the simple vote is picked", () => {
    render("secure");

    document.querySelector("[data-testid='simple-point']").click();

    expect(card("simple").classList.contains("is-selected")).toBe(true);
    expect(twoFactor().hidden).toBe(true);
    expect(twoFactor().disabled).toBe(true);
  });

  it("starts in step with a radio restored by the browser", () => {
    render("simple");
    document.querySelector("[data-security-choice='secure']").checked = true;

    setupSecurity();

    expect(twoFactor().hidden).toBe(false);
    expect(card("secure").classList.contains("is-selected")).toBe(true);
  });

  it("does nothing on a page without the Security form", () => {
    document.body.innerHTML = "<p>Dashboard</p>";

    expect(() => setupSecurity()).not.toThrow();
  });
});
```
Run: `npx jest app/packs/src/decidim/elections/vocdoni/admin/security.test.js`
Expected: `Tests:       3 failed, 1 passed, 4 total` (the old script never un-hides the block)

Step 2: implement

`app/packs/src/decidim/elections/vocdoni/admin/security.js` (full content):
```js
/**
 * Security tab: progressive enhancement, nothing load-bearing.
 *
 * The server renders every state from what is saved. This keeps the page in
 * step while the admin changes things without saving:
 *
 * 1. The whole vote-type card selects its option, and the selected card is
 *    highlighted (browsers without `:has()`). Without JavaScript the radio
 *    and the card title still do.
 * 2. The one-time code block is shown, and its fieldset usable, only while
 *    the secret vote is selected.
 *
 * The section header is a native `<details>`, so it needs nothing here. The
 * resulting configuration is summarised on the Dashboard, from saved data.
 *
 * Selectors are ids with a `js-` prefix or `data-` attributes, never classes.
 */

const CHOICE_ID = "js-security-choice";
const TWO_FACTOR_ID = "js-security-two-factor";

const setupSecurity = () => {
  const choice = document.getElementById(CHOICE_ID);
  const twoFactor = document.getElementById(TWO_FACTOR_ID);

  if (!choice || !twoFactor) {
    return;
  }

  const radios = Array.from(choice.querySelectorAll("[data-security-choice]"));
  const cards = Array.from(choice.querySelectorAll("[data-security-choice-card]"));

  const selected = () => {
    const radio = radios.find((input) => input.checked);
    return radio
      ? radio.dataset.securityChoice
      : "";
  };

  const sync = () => {
    const value = selected();
    cards.forEach((card) => {
      card.classList.toggle("is-selected", card.dataset.securityChoiceCard === value);
    });

    // Hidden and disabled together: a disabled fieldset submits nothing, so
    // a simple vote never carries a stale code choice.
    const usable = value === "secure";
    twoFactor.hidden = !usable;
    twoFactor.disabled = !usable;
  };

  cards.forEach((card) => {
    card.addEventListener("click", (event) => {
      // Links, the radio and its label already do their own thing, and a
      // click that ends a text selection is not a choice.
      if (event.target.closest("a, input, label") || String(window.getSelection())) {
        return;
      }
      const radio = card.querySelector("[data-security-choice]");
      if (radio && !radio.checked) {
        radio.checked = true;
        radio.dispatchEvent(new Event("change", { bubbles: true }));
      }
    });
  });

  radios.forEach((radio) => radio.addEventListener("change", sync));

  // Form state survives a back-navigation, so start in step with it.
  sync();
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", setupSecurity);
} else {
  setupSecurity();
}

export default setupSecurity;
```

Run:
```
npx jest app/packs/src/decidim/elections/vocdoni/admin/security.test.js
npm test
npm run lint
```
Expected:
```
Tests:       4 passed, 4 total
Tests:       205 passed, 205 total
✖ 2 problems (0 errors, 2 warnings)     # both pre-existing: voter/link_code.js (unused eslint-disable) and build/vote.mjs (import/no-named-as-default-member)
```

Step 3: commit
```
git add app/packs/src/decidim/elections/vocdoni/admin/security.test.js
git commit -m "feat(security): toggle the one-time code block without the summary line" -- app/packs/src/decidim/elections/vocdoni/admin/security.js app/packs/src/decidim/elections/vocdoni/admin/security.test.js
```

Interfaces this task provides to later tasks: `setupSecurity()` (default
export), a no-op on pages without `#js-security-choice`/`#js-security-two-factor`
(the Dashboard loads only the stylesheet, not this script).

### Task 5: Dashboard card
Model: sonnet   Repo: /Users/ferran/Repos/decidim/decidim-secure_elections
Files:
- `app/views/decidim/elections/vocdoni/admin/dashboard/_security.html.erb` (new)
- `app/views/overrides/decidim/elections/admin/elections/dashboard.html.erb` (new, generated)
- `lib/decidim/elections/vocdoni/engine.rb` (edit)
- `app/forms/decidim/elections/vocdoni/admin_forms/security_form.rb` (edit)
- `config/locales/security.en.yml` (edit)

Goal: R2, R3, AC3, AC4: the "Your security configuration" card, rendered by a
pinned copy of upstream's dashboard that the engine puts first on
`Decidim::Elections::Admin::ElectionsController`'s view path only.

Decisions and why:
- Two render lines, not one. AC3 places the card after Results (published
  branch) and before Main (unpublished branch); those are different branches of
  upstream's `if`, so no single line can do both. The drift spec asserts
  exactly these two added lines. (R2/AC4 say "one added line"; flagged.)
- Directory `app/views/overrides`, not `app/views/decidim/elections/admin/elections/`.
  Rails puts every engine's `app/views` on every controller's view path in an
  initializer order this gem does not control, so a copy at the upstream
  virtual path would win or lose by load order and would shadow upstream for
  every controller. `app/views/overrides` is prepended to `ElectionsController`
  alone (its `_view_paths` class attribute; parents and `ActionController::Base`
  are untouched, asserted by the spec), holds exactly one file (asserted), and
  through the shared `app/views` path the copy is only reachable as
  `overrides/decidim/…`, which nothing renders. It holds no Ruby file, so
  Zeitwerk skips it. Lazy lookups in the copy (`t(".title")`, `t(".subtitle")`)
  resolve against the virtual path `decidim/elections/admin/elections/dashboard`,
  as upstream's do. Note: the host application's own `app/views` comes after
  this path for that controller, so a host-level override of the dashboard
  would be shadowed by ours.
- The level comes from `SecurityForm.level_for(election)` (a class method over
  `from_model(election).level`), so the card and the tab cannot disagree and
  the view does not build a form.
- The partial loads the module stylesheet itself
  (`append_stylesheet_pack_tag`), so the copy needs no extra line for it.
- `shield-line` is not registered by decidim-core; it joins `ICONS` (an
  unregistered icon is a 500).
- Review Focus names the copy as `app/views/decidim/elections/admin/elections/dashboard.html.erb`;
  with this decision it is
  `app/views/overrides/decidim/elections/admin/elections/dashboard.html.erb`
  (the controller should read Review Focus with that path).

Step 1: the failing tests exist (Task 1)
Run:
```
bundle exec rspec spec/requests/decidim/elections/vocdoni/admin/dashboard_spec.rb spec/lib/decidim/elections/vocdoni/dashboard_override_spec.rb spec/forms/decidim/elections/vocdoni/admin_forms/security_form_spec.rb
```
Expected: `21 examples, 13 failures`

Step 2: implement

`app/views/decidim/elections/vocdoni/admin/dashboard/_security.html.erb` (full content):
```erb
<%#
  "Your security configuration" card on upstream's Dashboard tab, rendered
  by the module's copy of upstream's dashboard
  (`app/views/overrides/decidim/elections/admin/elections/dashboard.html.erb`):
  after the Results card for a published election, before the Main card for
  an unpublished one.

  The level is the saved one (`SecurityForm.level_for`), so it reads the
  same as the Security tab after saving. The chrome is upstream's
  `card`/`card-divider`/`card-title`, as on the sibling cards.
%>
<% append_stylesheet_pack_tag "decidim_elections_vocdoni_admin", media: "all" %>
<% level = Decidim::Elections::Vocdoni::AdminForms::SecurityForm.level_for(election) %>
<div class="card vocdoni-security-summary" id="vocdoni-security-summary">
  <div class="card-divider">
    <h2 class="card-title">
      <%= icon "shield-line", class: "vocdoni-security-summary__icon" %>
      <span class="text-black font-bold"><%= t("title", scope: "decidim.elections.vocdoni.admin.dashboard.security") %></span>
    </h2>
  </div>

  <div class="card-section">
    <div class="row column">
      <p class="vocdoni-security-summary__sentence" data-security-level="<%= level %>">
        <%= t("sentences.#{level}", scope: "decidim.elections.vocdoni.admin.security.show.summary") %>
      </p>
    </div>
  </div>
</div>
```

Generate the copy (do not retype upstream by hand; this reproduces the
verified file byte for byte):
```
mkdir -p app/views/overrides/decidim/elections/admin/elections
UP="$DECIDIM_PATH/decidim-elections/app/views/decidim/elections/admin/elections/dashboard.html.erb"
shasum -a 256 "$UP"   # must print 7353b4ce482a28f4af761398d96cb3af4a8c93efaf0412454fb3d1e7b7927f27; stop if not
{ cat <<'HEADER'
<%#
  Copy of upstream's
  decidim-elections/app/views/decidim/elections/admin/elections/dashboard.html.erb
  at decidim/decidim 4c4d062fb9db171daac7fdad05d3bc5154ee15b2, with two lines
  added: the "Your security configuration" card, after the Results card for a
  published election and before the Main card for an unpublished one.

  Upstream's dashboard has no view hook, so the engine prepends
  `app/views/overrides` to `Decidim::Elections::Admin::ElectionsController`
  only (see `extend_upstream` in lib/decidim/elections/vocdoni/engine.rb).
  spec/lib/decidim/elections/vocdoni/dashboard_override_spec.rb pins the
  SHA-256 of upstream's file and fails on any upstream change: re-copy the
  file, re-add the two lines, update the pinned commit here and the digest
  in the spec.
%>
HEADER
awk 'NR==30{print "    <%= render partial: \"decidim/elections/vocdoni/admin/dashboard/security\" %>"} NR==32{print "    <%= render partial: \"decidim/elections/vocdoni/admin/dashboard/security\" %>"} {print}' "$UP"
} > app/views/overrides/decidim/elections/admin/elections/dashboard.html.erb
shasum -a 256 app/views/overrides/decidim/elections/admin/elections/dashboard.html.erb
```
Expected last line:
`269146ef442e3a08748e3cce1ec5cc216e8a1db5e5cb27074f5a06149a9d2f5d  app/views/overrides/decidim/elections/admin/elections/dashboard.html.erb`

The resulting middle of the file (upstream lines 24–35, with the two added
lines) reads:
```erb
  <% if election.published? %>
    <div class="flex flex-col md:flex-row gap-4 w-full mb-10">
      <div class="flex-1"><%= render partial: "decidim/elections/admin/dashboard/status" %></div>
      <div class="flex-1"><%= render partial: "decidim/elections/admin/dashboard/calendar" %></div>
    </div>
    <%= render partial: "decidim/elections/admin/dashboard/results" %>
    <%= render partial: "decidim/elections/vocdoni/admin/dashboard/security" %>
  <% else %>
    <p class="mb-4"><%= t(".subtitle") %></p>
    <%= render partial: "decidim/elections/vocdoni/admin/dashboard/security" %>
    <%= render partial: "decidim/elections/admin/dashboard/main" %>
    <%= render partial: "decidim/elections/admin/dashboard/questions" %>
    <%= render partial: "decidim/elections/admin/dashboard/census" %>
  <% end %>
```

`lib/decidim/elections/vocdoni/engine.rb`, three edits.

Edit 1, old:
```ruby
      # upstream election. No upstream file is patched at runtime.
```
new:
```ruby
      # upstream election. No upstream file is patched at runtime; one
      # upstream view, the Dashboard, is shadowed for its own controller by
      # a pinned copy (see `extend_upstream`).
```

Edit 2 (end of the `to_prepare` block in `extend_upstream`), old:
```ruby
            Decidim::Elections::VotesController.include(
              Decidim::Elections::Vocdoni::RedirectsVoterToBooth
            )
          end
        end
```
new:
```ruby
            Decidim::Elections::VotesController.include(
              Decidim::Elections::Vocdoni::RedirectsVoterToBooth
            )

            # The "Your security configuration" card on upstream's Dashboard
            # tab. Upstream's dashboard has no view hook, so this gem ships a
            # copy of it with the card's render line added, and puts the
            # copy's directory first on this one controller's view path.
            #
            # Why a directory of its own, `app/views/overrides`: every
            # engine's `app/views` is on every controller's view path, in an
            # order this gem does not control, so a copy under `app/views`
            # proper might or might not win, and would shadow upstream's file
            # for every controller that renders it. `app/views/overrides` is
            # added here, to `ElectionsController` only, and holds that one
            # file (a spec lists it). Through the shared `app/views` path the
            # copy is only reachable as `overrides/…`, which nothing renders;
            # it holds no Ruby file, so Zeitwerk skips it.
            #
            # The copy's header names the upstream file and Decidim commit,
            # and `spec/lib/decidim/elections/vocdoni/dashboard_override_spec.rb`
            # fails as soon as upstream changes it. Guarded so a reload that
            # keeps the class does not stack the path twice.
            overrides = File.expand_path("app/views/overrides", Decidim::Elections::Vocdoni::Engine.root)
            elections_controller = Decidim::Elections::Admin::ElectionsController
            elections_controller.prepend_view_path(overrides) unless elections_controller.view_paths.map(&:to_s).include?(overrides)
          end
        end
```

Edit 3 (`ICONS`), old:
```ruby
          shield-check-line shield-keyhole-line smartphone-line
```
new:
```ruby
          shield-check-line shield-keyhole-line shield-line smartphone-line
```

`app/forms/decidim/elections/vocdoni/admin_forms/security_form.rb`, old:
```ruby
          # Summary levels shown on the tab, from least to most protected.
          LEVELS = %w(basic strong strongest).freeze
```
new:
```ruby
          # The saved level of an election, for read-only surfaces such as the
          # Dashboard card: the level of the form the Security tab would
          # render for it.
          def self.level_for(election)
            from_model(election).level
          end

          # Security levels, from least to most protected; each has a
          # sentence on the Dashboard card (`show.summary.sentences.*`).
          LEVELS = %w(basic strong strongest).freeze
```

`config/locales/security.en.yml`, old:
```yaml
        admin:
          # The Security tab. Written for the person running the vote, not for
```
new:
```yaml
        admin:
          # The "Your security configuration" card this engine adds to
          # upstream's Dashboard tab.
          dashboard:
            security:
              title: "Your security configuration"
          # The Security tab. Written for the person running the vote, not for
```

Run:
```
bundle exec rspec spec/requests/decidim/elections/vocdoni/admin/dashboard_spec.rb spec/lib/decidim/elections/vocdoni/dashboard_override_spec.rb spec/forms/decidim/elections/vocdoni/admin_forms/security_form_spec.rb
bundle exec rspec spec/requests
bundle exec rubocop lib/decidim/elections/vocdoni/engine.rb app/forms/decidim/elections/vocdoni/admin_forms/security_form.rb
ls -R app/views/overrides
```
Expected:
```
21 examples, 0 failures
16 examples, 0 failures
2 files inspected, no offenses detected
(only decidim/elections/admin/elections/dashboard.html.erb under app/views/overrides)
```
The engine change is in `to_prepare`/`after_initialize`: a running
development server must be restarted to pick it up.

Step 3: commit
```
git add app/views/decidim/elections/vocdoni/admin/dashboard/_security.html.erb app/views/overrides/decidim/elections/admin/elections/dashboard.html.erb
git commit -m "feat(security): add the security configuration card to the dashboard" -- app/views/decidim/elections/vocdoni/admin/dashboard/_security.html.erb app/views/overrides/decidim/elections/admin/elections/dashboard.html.erb lib/decidim/elections/vocdoni/engine.rb app/forms/decidim/elections/vocdoni/admin_forms/security_form.rb config/locales/security.en.yml
```

Interfaces this task provides to later tasks:
`SecurityForm.level_for(election)`; key
`decidim.elections.vocdoni.admin.dashboard.security.title`; the override
directory `app/views/overrides` (Task 6 excludes it from i18n-tasks).

### Task 6: i18n-tasks configuration
Model: sonnet   Repo: /Users/ferran/Repos/decidim/decidim-secure_elections
Files: `config/i18n-tasks.yml` (full rewrite)

Goal: AC6 for i18n. `missing` and `unused` were already not clean on
`b85f88b` (`form.save` missing; the voting page's census labels and question
number unused). After tasks 3 and 5 the remaining reports are all
configuration, not copy:
- the override copy is upstream's file with upstream's keys (and relative keys
  i18n-tasks resolves against `overrides/…`): exclude `app/views/overrides`
  from the search;
- the two upstream keys the Security tab reuses (`edit.title`, `form.save`):
  `ignore_missing`;
- `census.fields.*` and `elections.show.question_number` live in
  `en.vote.yml` and are read by `build/vote.mjs`, not by Ruby: `ignore_unused`,
  next to the existing `votes.page.*` entry.

Step 1: see the reports
Run: `bundle exec i18n-tasks missing; bundle exec i18n-tasks unused`
Expected keys (tables): missing `decidim.elections.actions.{edit,preview,view}`,
`decidim.elections.admin.dashboard.publish_confirm`,
`decidim.elections.admin.elections.edit.title`,
`decidim.elections.admin.elections.form.{publish,save}`,
`overrides.decidim.elections.admin.elections.dashboard.{subtitle,title}`;
unused `decidim.elections.vocdoni.census.fields.{birthDate,email,memberNumber,name,nationalId,phone,surname}`,
`decidim.elections.vocdoni.elections.show.question_number`.

Step 2: implement

`config/i18n-tasks.yml` (full content):
```yaml
---

base_locale: en
locales: [en]

# `data.read` names every English source file this gem ships. Two survive:
# the Security tab / booth strings, and the strings the static voting page is
# built from. `i18n-tasks` would otherwise see only the first and report the
# second as unused everywhere it is referenced.
data:
  read:
    - config/locales/security.%{locale}.yml
    - config/locales/%{locale}.vote.yml
  write:
    - config/locales/security.%{locale}.yml

search:
  paths:
    - app/
    - lib/
  # The copy of upstream's Dashboard view uses upstream's keys, relative to
  # upstream's path; they are upstream's to keep.
  exclude:
    - app/views/overrides

ignore_unused:
  # The voting page is a static page built by `npm run build:vote`; the whole
  # subtree is read by JavaScript, not by Ruby. `build/vote.mjs` also folds in
  # the census field labels and the question number.
  - decidim.elections.vocdoni.votes.page.*
  - decidim.elections.vocdoni.census.fields.*
  - decidim.elections.vocdoni.elections.show.question_number

ignore_missing:
  - decidim.participatory_processes.scopes.global
  # Upstream decidim-elections keys, reused so the Security tab reads like
  # its sibling tabs.
  - decidim.elections.admin.elections.edit.title
  - decidim.elections.admin.elections.form.save
```

Run:
```
bundle exec i18n-tasks missing
bundle exec i18n-tasks unused
```
Expected: a single `✓ … No translations are missing.` line and a single
`✓ … Every translation is in use.` line (the praise word before them varies).

Step 3: commit
```
git commit -m "chore(i18n): scope i18n-tasks to the module's own keys" -- config/i18n-tasks.yml
```

Interfaces this task provides to later tasks: none.

### Task 7: CHANGELOG
Model: haiku   Repo: /Users/ferran/Repos/decidim/decidim-secure_elections
Files: `CHANGELOG.md` (edit)

Goal: AC8. Pure transcription.

Step 1: implement. In `CHANGELOG.md`, old:
```markdown
  **`decidim_elections_vocdoni:purge_stale_drafts`** rake tasks.

### Security
```
new:
```markdown
  **`decidim_elections_vocdoni:purge_stale_drafts`** rake tasks.
- **"Your security configuration" card on the Dashboard tab** — one sentence
  stating the election's saved security level (simple vote, secret and
  verifiable vote, or secret and verifiable vote with a one-time code). Shown
  after the Results card of a published election and before the Main card of
  an unpublished one. Upstream's Dashboard has no view hook, so the module
  ships a copy of its `dashboard.html.erb` with the card added, on the view
  path of `Decidim::Elections::Admin::ElectionsController` only; a spec pins
  the SHA-256 of upstream's file and fails when upstream changes it.

### Changed

- **Security tab redesigned to the Decidim 2026 design** (Decidim Design
  System): one card with a collapsible "How do you want to run this vote?"
  header, two option cards with plain bullet points and a "Best for" footer
  band, the "Recommended for binding decisions" pill, an inline "Good to know"
  row, and the one-time-code block inside the same card, shown only while the
  secret vote is selected. The page title is now "Edit election", as on the
  other election tabs. The "Why it matters" section, the comparison table and
  the configuration summary line are gone from the tab; the summary moves to
  the Dashboard card. Colours and type sizes are Design System tokens
  (`--color-color-*` and `--measure-*` custom properties from
  decidim/decidim#17722) with the Figma values as fallbacks, so the tab looks
  the same before and after that pull request reaches Decidim.

### Security
```

Run: `git diff --stat -- CHANGELOG.md`
Expected: `CHANGELOG.md | 23 +++++++++++++++++++++++`

Step 2: commit
```
git commit -m "docs(changelog): note the security tab redesign and dashboard card" -- CHANGELOG.md
```

Interfaces this task provides to later tasks: none.

## Merge and release
<!-- Not copied into briefs; the controller executes this after the gate audit. -->
1. Full suites, from the module root after `source ~/Repos/decidim/dev-env.sh`:
   - `bundle exec rspec` → `142 examples, 0 failures` (checked in the clone)
   - `npm test` → `Tests: 205 passed, 205 total`
   - `bundle exec rubocop --parallel` → `46 files inspected, no offenses detected`
   - `npm run lint` → `0 errors` (2 pre-existing warnings outside this change)
   - `npm run stylelint` → no output, exit 0
   - `bundle exec i18n-tasks missing` / `bundle exec i18n-tasks unused` → both `✓`
   - `git diff --quiet b85f88b -- public/vocdoni app/packs/src/decidim/elections/vocdoni/voter build config/locales/en.vote.yml && echo unchanged` → `unchanged` (AC6, non-goals)
   - `npm run build:vote && git diff --quiet -- public/vocdoni && echo in-step` → `in-step` (the CI artefact check; on a diff, stop: this change must not touch the voting page, and `git checkout -- public/vocdoni` restores it)
   - `grep -E "webpack [0-9.]+ compiled" spec/decidim_dummy_app/log/test.log | tail -1` → no "errors"
2. Visual check by the controller (AC7), development app at 1536 px wide,
   against `docs/design/security-tab/figma-*.png`:
   - Restart the dev server (`cd development_app && bin/dev`): the engine and
     icon changes load at boot.
   - Security, simple vote:
     `http://localhost:3000/en/admin/participatory_processes/hope-drill/components/5/manage/elections/1/security`
     → `figma-security-simple-selected.png` (no code block). Click the secret
     card (anywhere but the text) → the code block appears without saving and
     the selected border/footer band move; keyboard: Tab to a radio, arrow
     keys switch, focus ring visible; the header collapses with Enter/Space
     and the chevron turns. Save with the secret vote → lands on Dashboard.
   - Security, secret vote: same URL → `figma-security-secure-selected.png`.
   - Dashboard, unpublished:
     `http://localhost:3000/en/admin/participatory_processes/hope-drill/components/5/manage/elections/1/dashboard`
     → card between the subtitle and Main.
   - Dashboard, published (election 1 is the only seeded election and is
     unpublished; publish it without callbacks, then undo):
     ```
     cd development_app
     bin/rails runner 'e = Decidim::Elections::Election.find(1); puts e.start_at.iso8601; e.update_columns(published_at: Time.current, start_at: 1.hour.ago)'
     # check the dashboard URL above against figma-dashboard-ended.png (card after Results, sentence for the saved level)
     bin/rails runner 'Decidim::Elections::Election.find(1).update_columns(published_at: nil, start_at: Time.zone.parse("<the iso8601 printed above>"))'
     ```
     `update_columns` skips callbacks, so no publish event and no Vocdoni job
     fires. The chevron direction follows the PNG (down when open), not the
     README sentence "pointing up when expanded"; confirm with the owner.
   - Contrast: the pairs are recorded in `_tokens.scss`; no new pair is
     introduced.
3. Merge order: `feature/design-system-security-tab` → `main` (single repo).
4. Release: none. No version bump; the entries sit under `## [Unreleased]` in
   `CHANGELOG.md`. `docs/design/security-tab/README.md` stays untouched.
5. **Owner OK required before:** pushing the branch; opening the PR.
6. Post-merge checks: CI on `main` green, in particular "Ruby tests" (the
   drift spec runs against Decidim `develop` as CI resolves it, so an upstream
   change to `dashboard.html.erb` after `4c4d062` fails there first — that is
   the intended re-sync signal) and "Built voting page is in step with its
   sources".
