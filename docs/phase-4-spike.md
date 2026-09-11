# Phase-4 spike — proving the upstream extension surface

_Branch: `spike/phase-4-registration`. Author: 2026-09-11._

This branch proves that the two upstream hooks staged on `vocdoni/decidim` — [`#1` results_availability registry](https://github.com/vocdoni/decidim/pull/1) and [`#2` `PublishElection` `with_events`](https://github.com/vocdoni/decidim/pull/2) — are enough to plug this module in as an optional Vocdoni "security layer" on top of upstream `decidim-elections`, without patching any upstream file at runtime.

## What the spike does

A single Rails engine, loaded only when `PHASE_4_SPIKE=1`, wires three things:

1. Registers a census manifest `:vocdoni_secure` on `Decidim::Elections.census_registry` — appears as **"Secure via Vocdoni (spike)"** in the census-manifest combobox on a new election.
2. Registers `:blockchain_backed` on `Decidim::Elections.register_results_availability` — appears as **"Blockchain-backed (spike)"** in the results-availability select on the election form.
3. Subscribes to `decidim.elections.admin.publish_election:after` — writes `[phase-4-spike] publish_election:after fired for election #<id>` to the Rails log when the admin publishes an election.

**All three come out of upstream hooks.** No file under `decidim-elections/` is monkey-patched, decorated, or reopened.

Layout:

```
lib/decidim/secure_elections/
  phase_4_spike.rb                          # engine + AdminForm + 3 initializers
  phase_4_spike/
    config/locales/en.yml                   # i18n for the two labels
    views/decidim/secure_elections/
      phase_4_spike/_admin_form.html.erb    # dummy census admin partial
```

The engine is only required when `PHASE_4_SPIKE=1` (see the tail of `lib/decidim/secure_elections.rb`), so the existing production code path on `main` is unaffected.

## How to verify locally

Prereqs: Ruby 3.4.7 (`.ruby-version`), Postgres, node/yarn.

**Option A — consume via git ref (no local Decidim checkout needed):**

```bash
bundle config unset build.decidim  # if previously set
export DECIDIM_REPO=https://github.com/vocdoni/decidim
export DECIDIM_REF=phase-4/integration
export PHASE_4_SPIKE=1
bundle install
bin/rails decidim:choose_target_plugins
bundle exec rake test_app                  # from decidim-dev; generates spec/decidim_dummy_app
cd spec/decidim_dummy_app
bin/rails db:setup
bin/rails s
```

Then in the browser, `http://localhost:3000/admin` → login as the seeded admin → create an Elections component in a participatory space → create a new election → verify:

- [ ] Census-manifest combobox lists "Secure via Vocdoni (spike)".
- [ ] Results-availability select lists "Blockchain-backed (spike)".
- [ ] Publishing the election writes `[phase-4-spike] publish_election:after fired for election #N` to `log/development.log`.

**Option B — consume via local Decidim checkout (faster iteration on the fork):**

```bash
git clone https://github.com/vocdoni/decidim ~/src/vd/decidim
cd ~/src/vd/decidim
git checkout phase-4/integration
export DECIDIM_PATH=~/src/vd/decidim
export PHASE_4_SPIKE=1
cd ~/src/vd/decidim-secure_elections
bundle install
# ... same as above from `rake test_app`
```

## What the spike does NOT prove

- **End-to-end Vocdoni voting flow.** The `AdminForm` is a placeholder; the `voter_form_partial` is `nil` (no ballot booth). This spike proves *the extension surface exists*, not that a full Vocdoni integration slots into it. A production port would flesh out both partials, the `after_update_command` on the manifest, and the `after` subscriber (which today only logs — a real backend would enqueue a `PublishToVocdoniJob`).
- **The `voter_form_partial` shape.** Upstream expects a Rails partial that renders an authentication form for the voter. The Vocdoni voter flow is a JS SPA at `/vocdoni/vote.html`. A production port would mount that bundle from inside the partial via a `<div id="vocdoni-booth" data-election-id="…">`.
- **DB schema alignment.** The current `SecureElections` gem owns `decidim_vocdoni_elections` (its own model). A production port would replace that with a decidim-elections `Election` + a lightweight `Decidim::SecureElections::VocdoniProcess` sidecar keyed off `decidim_election_id`.

## Verdict — TO BE FILLED after first run

The spike code compiled logically without a running Ruby interpreter available in the authoring environment (see caveat below). Once someone runs Option A or B and observes the three success criteria, fill this section with one of:

- ✅ **"Shape works as designed."** Extension surface is sufficient; no upstream changes beyond `#1` and `#2` are needed to move forward with the port. Next step: open the two PRs against `decidim/decidim` upstream.
- ⚠️ **"Shape works but needs X adjustment."** List the concrete change.
- ❌ **"Shape doesn't work — Y broke."** Describe the failure, whether it's on our side or requires a third upstream PR.

## Authoring caveat

The environment this branch was authored in did not have Ruby installed. All patches were written by inspection against the upstream sources; no `bundle install` or `rails s` was run. If Bundler resolution, engine autoload order, or the `after_initialize` hook order surprises us in practice, the diff is small enough (~120 lines across 4 files including the Gemfile edit) to iterate on quickly.
