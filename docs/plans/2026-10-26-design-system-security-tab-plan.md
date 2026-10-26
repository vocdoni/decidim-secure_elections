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
  of upstream's `dashboard.html.erb` that adds one `render`. A spec pins the SHA-256 of
  upstream's file so any upstream change fails the suite and forces a re-sync. The copy is
  marked with a header comment naming the upstream path and the pinned Decidim commit.
- R3 The Dashboard card reuses upstream's `card`/`card-divider`/`card-title` chrome.
- R4 The one-time-code block is server-rendered `hidden` (and the fieldset `disabled`) when
  the simple vote is selected; `security.js` toggles both without saving.
- R5 `_why_it_matters.html.erb`, the summary line on the Security tab, their SCSS and i18n
  keys (`show.why.*`, `show.summary.levels.*`, `show.choice.*.summary`,
  `show.two_factor.simple_note`, `show.choice.selected`) are removed. `show.summary.sentences.*`
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
- Only `en` locale files are edited; `config/locales/security.en.yml` keys must pass `i18n-tasks normalize --locales en`.
- Never print, log or commit secrets (the `VOCDONI_API_KEY` in `mise.local.toml`).
- Lint before committing: `bundle exec rubocop --parallel`, `npm run lint`, `npm run stylelint`.

## Review Focus
- `lib/decidim/elections/vocdoni/engine.rb` `to_prepare` block: the prepended view path must only affect `Decidim::Elections::Admin::ElectionsController` and must not shadow any other upstream view (list the files in the prepended directory in the spec).
- `app/views/decidim/elections/admin/elections/dashboard.html.erb` (module copy): byte-identical to upstream except the one added line; the drift spec must fail on any upstream change.
- `app/controllers/decidim/elections/vocdoni/admin/security_controller.rb`: unchanged permission checks (`enforce_permission_to`); the request specs must prove denial for non-admins.
- `app/views/decidim/elections/vocdoni/admin/security/_choice.html.erb`: `aria-labelledby`/`aria-describedby` wiring survives the restyle; radios still post `enable_vocdoni` "true"/"false".
- `security.js`: the summary-sync code is removed; the card and fieldset toggles keep working without the summary element present.

## Task order and parallelism
<!-- The plan drafter fills this table and the tasks below. -->
