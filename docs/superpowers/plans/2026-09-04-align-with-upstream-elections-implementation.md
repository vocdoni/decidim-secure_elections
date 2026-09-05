# Align admin UI with upstream decidim-elections — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebase the `decidim-secure_elections` admin editor on `decidim-elections`'s IA — four persistent tabs (Main / Questions / Census / Dashboard), accordion-Main, drag-reorderable Questions, single branching Dashboard — while preserving vd's protocol-required carve-outs (no `per_question` results, live monitor, `confirm_irreversible` checkbox on publish).

**Architecture:** One PR against `feedback/aulet-round-1`, seven internal commits corresponding to Tasks 1–7. Each task lands a runnable state (nav still renders, existing screens still work) until the last mile. The DOM contracts, i18n keys, and file paths are all locked in the spec — this plan sequences them and adds acceptance criteria.

**Tech Stack:** Ruby on Rails 7 (Decidim ~0.30), Slim/ERB views, RSpec + Capybara for system specs, Shakapacker for packs, Foundation + Tailwind utilities. Drag: `html5sortable` 0.14.0 (already available via Decidim). Accordion: `a11y-accordion-component` (already available). JS clone/add/remove: `DynamicFieldsComponent` from `decidim-admin`.

## Global Constraints

- **Spec is the source of truth for DOM contracts, i18n, and file naming.** `docs/superpowers/specs/2026-09-04-align-with-upstream-elections-design.md`. Where this plan says "per spec §N", copy the ERB / class list / attribute names verbatim from that section.
- **Every commit ships a working admin.** No half-migrated states between tasks — after Task 1, existing bodies still render inside the new frame; after each subsequent task, the touched screen is done end-to-end.
- **Never `--no-verify`.** Hooks run on every commit; if a linter fails, fix the underlying issue.
- **PR-only workflow.** Push to `feedback/aulet-round-1`; do not push to `main`.
- **SaaS `InitialStatus` PR is a prerequisite for Task 5 landing on prod**, but is assumed to be merged by the time we're coding Task 5 — write the vd side as if the API accepts `InitialStatus: PAUSED` without any feature check.
- **No autosave.** Any `data-autosave-*` attribute or JS wiring encountered gets removed, never expanded.
- **`start_immediately` and `manual_start?` (old vd meaning) are dead words.** The rename is a semantic flip; the "Naming gotcha" section of the spec dictates ordering: delete old method first, then add the new column and rewire call sites.
- **DB is dropped, not migrated.** No migration files; regenerate schema from scratch. Seeds and factories updated in the same commit as the column change.

## File Structure

**Created:**
- `app/views/decidim/secure_elections/admin/elections/_tabs_menu.html.erb` — the four-tab strip.
- `app/views/decidim/secure_elections/admin/elections/_form.html.erb` — Main form with three accordion cards.
- `app/views/decidim/secure_elections/admin/questions/_form.html.erb` — outer wrapper + template + list.
- `app/views/decidim/secure_elections/admin/questions/_question.html.erb` — one question card.
- `app/views/decidim/secure_elections/admin/questions/_response_option.html.erb` — one option card.
- `app/views/decidim/secure_elections/admin/questions/_response_option_template.html.erb` — blueprint for cloning.
- `app/views/decidim/secure_elections/admin/census/preview.html.erb` — 5-row preview partial.
- `app/views/decidim/secure_elections/admin/elections/dashboard.html.erb` — branching page.
- `app/views/decidim/secure_elections/admin/dashboard/_checklist.html.erb`, `_main.html.erb`, `_questions.html.erb`, `_census.html.erb`, `_publish.html.erb`, `_status.html.erb`, `_calendar.html.erb`, `_results.html.erb`.
- `app/controllers/decidim/secure_elections/admin/dashboard_controller.rb`.
- `app/packs/src/decidim/secure_elections/admin/questions_editor.js` — thin wrapper that calls `createEditableForm()`.
- System specs: `spec/system/decidim/secure_elections/admin/main_spec.rb`, `questions_editor_spec.rb`, `census_spec.rb`, `dashboard_spec.rb`, `elections_index_spec.rb`.

**Modified:**
- `lib/decidim/secure_elections/admin_engine.rb` — routes trimmed (`calendar`, `setup` gone; `dashboard` added), menu re-registered as four tabs.
- `app/models/decidim/secure_elections/election.rb` — `NAV_STEPS` shrinks, old `manual_start?` deleted, column names change.
- `app/forms/decidim/secure_elections/admin/election_form.rb` — absorbs `ElectionCalendarForm` attributes, adds `manual_start` + `results_availability`.
- `app/forms/decidim/secure_elections/admin/election_questions_form.rb` — ballot-wide `question_type` and `result_visibility` removed.
- `app/forms/decidim/secure_elections/admin/question_form.rb` — `question_type` added (per-question).
- `app/commands/decidim/secure_elections/admin/publish_election.rb` — payload gains `paused` + `interruptible`.
- `app/commands/decidim/secure_elections/admin/saves_election_questions.rb` — copy-down loop for `question_type` deleted.
- `app/packs/stylesheets/decidim/secure_elections/admin/editor.scss` — borderless-title carve-out deleted, `.vocdoni-step-nav` block deleted.
- `config/locales/en.yml` and every sibling locale — key renames (`start_immediately` → `manual_start`, step 5 label already `publish`, tabs, dashboard strings). Non-en locales: leave English fallback; do NOT hand-translate (i18n-tasks pass at Task 7).

**Deleted:**
- `app/controllers/decidim/secure_elections/admin/calendar_controller.rb`
- `app/controllers/decidim/secure_elections/admin/setup_controller.rb`
- `app/controllers/decidim/secure_elections/admin/monitor_controller.rb` (folds into Dashboard)
- `app/views/decidim/secure_elections/admin/calendar/*`
- `app/views/decidim/secure_elections/admin/setup/show.html.erb`
- `app/views/decidim/secure_elections/admin/monitor/*` (markup moves to `dashboard/_results` and `_status`)
- `app/views/decidim/secure_elections/admin/shared/_nav.html.erb`
- `app/views/decidim/secure_elections/admin/shared/_step_footer.html.erb`
- `app/views/decidim/secure_elections/admin/shared/_wizard.html.erb`
- `app/views/decidim/secure_elections/admin/elections/_field_templates.html.erb` (replaced by `<script type="text/template">`)
- `app/forms/decidim/secure_elections/admin/election_calendar_form.rb`
- `app/commands/decidim/secure_elections/admin/update_election_calendar.rb`
- `app/commands/decidim/secure_elections/admin/setup_election.rb` (behaviour folds into `PublishElection` command)

---

### Task 1: Frame + four-tab strip

Registers the new admin menu, wires the tabs partial into every editor screen, deletes the wizard-progression UI. After this task, every existing screen still renders its current body, but inside the new frame.

**Files:**
- Create: `app/views/decidim/secure_elections/admin/elections/_tabs_menu.html.erb`
- Modify: `lib/decidim/secure_elections/admin_engine.rb:80-105` (menu block); `app/models/decidim/secure_elections/election.rb` (`NAV_STEPS`)
- Modify: every existing view under `admin/*/` to replace `render "…/shared/nav"` with `render "…/elections/tabs_menu"`
- Delete: `app/views/decidim/secure_elections/admin/shared/_nav.html.erb`, `_step_footer.html.erb`, `_wizard.html.erb`
- Modify: `app/packs/stylesheets/decidim/secure_elections/admin/editor.scss` — drop the entire `.vocdoni-step-nav` block (lines 17–36 today)
- Test: `spec/system/decidim/secure_elections/admin/nav_spec.rb`

**Interfaces:**
- Produces: `admin_tabs(:admin_secure_elections_menu).render` renders exactly four `<li>` entries in the order **Main / Questions / Census / Dashboard**. Tabs are `<a>` when reachable, `<span class="sidebar-menu__item-disabled">` when blocked, `<a aria-current="page">` on the active screen. Menu key `:admin_secure_elections_menu`.
- Consumes: existing `Election#step_reachable?` predicate (kept as-is for the "disabled tab" rule; the four new keys are `:main`, `:questions`, `:census`, `:dashboard`, mapped from the old five wizard steps).

- [ ] **Step 1: Write the failing system spec**

Create `spec/system/decidim/secure_elections/admin/nav_spec.rb`. Test: on the elections edit page, the `.main-tabs-menu` renders exactly `["Main", "Questions", "Census", "Dashboard"]` in that order.

- [ ] **Step 2: Run the spec, watch it fail**

```bash
bundle exec rspec spec/system/decidim/secure_elections/admin/nav_spec.rb
```
Expected: FAIL — either the tab strip still says the six old labels, or the menu key `:admin_secure_elections_menu` is unregistered.

- [ ] **Step 3: Register the new menu**

In `admin_engine.rb`, replace the `Decidim.menu :admin_vocdoni_menu do |menu|` block with a `Decidim.menu :admin_secure_elections_menu do |menu|` block that adds the four entries. The `dashboard` entry points to `dashboard_election_path` (route added in Task 5; for this task just create a stub route pointing at the existing `elections#show`, so links resolve).

Update `Election::NAV_STEPS` to `%i(main questions census dashboard)`; the internal keys stay singular per screen so `step_reachable?` still keys on them. Map: `:main` reachable iff currently `:details` was reachable (i.e. always); `:questions` iff `details_complete?`; `:census` iff also `questions_complete?`; `:dashboard` always reachable (blocking is checklist-driven inside the page, not in the tab).

- [ ] **Step 4: Create `_tabs_menu.html.erb`**

```erb
<div class="main-tabs-menu">
  <div class="main-tabs-menu__tabs">
    <%= admin_tabs(:admin_secure_elections_menu).render %>
  </div>
  <div class="main-tabs-menu__buttons">
    <%= yield if block_given? %>
  </div>
</div>
```

- [ ] **Step 5: Point every existing view at the new partial**

`grep -rln "shared/nav" app/views/decidim/secure_elections/admin/` gives the list. Replace `render partial: "decidim/secure_elections/admin/shared/nav", …` with `render "decidim/secure_elections/admin/elections/tabs_menu"`.

- [ ] **Step 6: Delete the wizard partials and CSS block**

```bash
git rm app/views/decidim/secure_elections/admin/shared/_nav.html.erb \
       app/views/decidim/secure_elections/admin/shared/_step_footer.html.erb \
       app/views/decidim/secure_elections/admin/shared/_wizard.html.erb
```

Remove the `.vocdoni-step-nav { … }` block from `editor.scss` (currently lines 17–36).

- [ ] **Step 7: Run the spec, watch it pass**

```bash
bundle exec rspec spec/system/decidim/secure_elections/admin/nav_spec.rb
```
Expected: PASS. Also run the full existing system-spec suite to confirm nothing else broke:
```bash
bundle exec rspec spec/system/
```
Expected: same green baseline as before this task.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "frame: four-tab strip replaces the wizard nav

Registers :admin_secure_elections_menu with Main / Questions / Census /
Dashboard, wires the tabs_menu partial into every editor screen, drops
the wizard-progression stepper and its CSS. Existing screens still
render their current bodies inside the new frame; the Dashboard tab
stubs to the current elections#show until Task 5 wires the real
dashboard controller."
```

---

### Task 2: Main screen rewrite

Merges Details + Schedule into one form with three accordion cards; drops autosave; renames `start_immediately` → `manual_start` (real semantic flip); renames `start_time` → `start_at`, `end_time` → `end_at`. DB dropped, schema regenerated in the same commit.

**Files:**
- Create: `app/views/decidim/secure_elections/admin/elections/_form.html.erb` (three accordion cards)
- Modify: `app/views/decidim/secure_elections/admin/elections/{new,edit}.html.erb` to render the new `_form` partial inside the `.item__edit.item__edit-1col` frame with a right-hand sticky `Save and continue` button
- Modify: `app/forms/decidim/secure_elections/admin/election_form.rb` — add `manual_start` (Boolean, default false), `start_at`, `end_at`, `results_availability` (default "after_end"); drop `autosave_*`
- Modify: `app/models/decidim/secure_elections/election.rb` — delete the old `manual_start?` method (per spec Naming gotcha), rename `start_time`→`start_at`, `end_time`→`end_at`, add `manual_start` boolean column, add `results_availability` enum limited to `real_time` / `after_end`
- Modify: `db/schema.rb` — regenerate; no migration file
- Modify: `app/packs/stylesheets/decidim/secure_elections/admin/editor.scss` — delete `.vocdoni-editor__title` and `.vocdoni-question__title` borderless-heading blocks (currently lines ~110–150)
- Modify: `app/views/decidim/secure_elections/admin/elections/_details_fields.html.erb` — delete `data-autosave-*` attributes and the `[data-vocdoni-status]` line; the borderless-title `<div class="vocdoni-editor__title">` wrapper becomes a plain field
- Modify: `app/packs/src/decidim/secure_elections/admin/editor.js` (and pack entry) — delete the autosave code path
- Delete: `app/controllers/decidim/secure_elections/admin/calendar_controller.rb`, `app/views/decidim/secure_elections/admin/calendar/*`, `app/forms/decidim/secure_elections/admin/election_calendar_form.rb`, `app/commands/decidim/secure_elections/admin/update_election_calendar.rb`
- Modify: `lib/decidim/secure_elections/admin_engine.rb` routes — remove `resource :calendar`
- Modify: `lib/decidim/secure_elections/test/factories.rb` and `lib/decidim/secure_elections/seeds.rb` — rename attributes
- Grep and rename every call site of `start_time` / `end_time` / `start_immediately` / `manual_start?` (old) — including GraphQL types in `lib/decidim/api/secure_elections_election_type.rb`
- Test: `spec/system/decidim/secure_elections/admin/main_spec.rb`

**Interfaces:**
- Produces: `ElectionForm#manual_start` (Boolean), `#start_at` (TimeWithZone), `#end_at` (TimeWithZone), `#results_availability` (`"real_time"` | `"after_end"`). `Election#manual_start?` reads the column directly. `Election#paused?` returns true when the on-chain status is PAUSED (added later; for this task, stub to `false` and let Task 5 wire it).
- Consumes (from Task 1): the tabs partial and the `:main` menu key.

- [ ] **Step 1: Write the failing system spec**

`spec/system/decidim/secure_elections/admin/main_spec.rb`. Test: visiting `/main` (redirected to `/edit`) renders exactly three collapsible cards with headings **Basic info**, **Calendar**, **Results availability**, in that order. Filling title + end_at + ticking a results radio and clicking `Save and continue` persists the changes.

- [ ] **Step 2: Run it, watch it fail**

```bash
bundle exec rspec spec/system/decidim/secure_elections/admin/main_spec.rb
```

- [ ] **Step 3: Rename columns and drop the DB**

```bash
bin/rails db:drop db:create
# Update schema.rb model attributes and factories; then:
bin/rails db:schema:load
```

Delete the old `Election#manual_start?` method (per spec Naming gotcha). Add the new `manual_start` column, `start_at`, `end_at`, `results_availability` enum.

- [ ] **Step 4: Merge the calendar form into ElectionForm**

Copy attribute declarations and validators from `ElectionCalendarForm` into `ElectionForm`, then delete the calendar form file. Rewrite validators per spec §"Rename plan" bullet 1: `start_at` optional; `end_at` after `start_at` when both present.

- [ ] **Step 5: Create `_form.html.erb` with three accordion cards**

Copy the accordion contract verbatim from spec §2 (the block starting `<div class="card form-<name>" data-controller="accordion" …>`). Three cards: `basic`, `calendar`, `results`. `basic` renders title + description + `stream_uri`. `calendar` renders `manual_start` checkbox + start/end datetime pickers in a `.md:flex.w-100`. `results` renders the two radios (`real_time`, `after_end`) with help copy.

- [ ] **Step 6: Rewrite `new.html.erb` / `edit.html.erb` with the frame**

Wrap in `.item__edit.item__edit-1col` → `.item__edit-form` + `.item__edit-sticky > .item__edit-sticky-container`. The sticky button is `<%= button_tag t(".save_and_continue"), form: "basic-election-form-edit", class: "button button__sm button__secondary" %>`.

- [ ] **Step 7: Rip out autosave**

Delete `data-autosave-*` attributes and the `<p data-vocdoni-status>` line from `_details_fields.html.erb`. In `editor.js` (or its pack), delete the setInterval + fetch that reads them.

- [ ] **Step 8: Delete the calendar controller / views / route**

```bash
git rm -r app/controllers/decidim/secure_elections/admin/calendar_controller.rb \
         app/views/decidim/secure_elections/admin/calendar \
         app/forms/decidim/secure_elections/admin/election_calendar_form.rb \
         app/commands/decidim/secure_elections/admin/update_election_calendar.rb
```

Remove `resource :calendar, …` from `admin_engine.rb` routes.

- [ ] **Step 9: Delete borderless-title CSS carve-out**

In `editor.scss`, delete the `&__title input,` selector block and the `.vocdoni-question__title input` block (currently lines ~110–150 by search).

- [ ] **Step 10: Rename call sites**

```bash
grep -rln "start_immediately\|start_time\|end_time\|\.manual_start?" app/ lib/ spec/ config/
```
Update each site per the semantic-flip rules in spec §"Rename plan".

- [ ] **Step 11: Run the Main spec + baseline**

```bash
bundle exec rspec spec/system/decidim/secure_elections/admin/main_spec.rb
bundle exec rspec spec/
```
Expected: PASS. Existing Calendar tests will fail — delete them (`spec/system/decidim/secure_elections/admin/calendar_*` or similar); their functionality is covered by the Main spec now.

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "main: three accordion cards, manual_start rename, autosave gone

Merges Calendar into Main as an accordion card; adds a Results
availability card with real_time and after_end radios (per_question is
excluded — vd's protocol doesn't support it). Renames start_immediately
→ manual_start with the semantic flip, and start_time/end_time →
start_at/end_at, per the spec's Naming gotcha ordering. DB is dropped
and reloaded from the fresh schema; the calendar step / controller /
form / view / route are all deleted. Autosave wiring gone from the
details fields and the editor pack. Borderless title carve-out on
.vocdoni-editor__title / .vocdoni-question__title deleted so titles
render the standard upstream way."
```

---

### Task 3: Questions rewrite

Full editor rewrite — upstream JS conventions (`html5sortable` + `DynamicFieldsComponent`), template blueprint pattern, per-question `question_type`, drag handle in the divider, soft-delete via hidden `deleted` boolean.

**Files:**
- Create: `app/views/decidim/secure_elections/admin/questions/_form.html.erb`
- Create: `app/views/decidim/secure_elections/admin/questions/_question.html.erb`
- Create: `app/views/decidim/secure_elections/admin/questions/_response_option.html.erb`
- Create: `app/views/decidim/secure_elections/admin/questions/_response_option_template.html.erb`
- Create: `app/packs/src/decidim/secure_elections/admin/questions_editor.js` — imports and calls `createEditableForm()` from `decidim-forms`
- Modify: `app/views/decidim/secure_elections/admin/questions/edit.html.erb` to render the new `_form` and load the pack
- Modify: `app/forms/decidim/secure_elections/admin/election_questions_form.rb` — delete `attribute :question_type` and `attribute :result_visibility`
- Modify: `app/forms/decidim/secure_elections/admin/question_form.rb` — add `attribute :question_type, String`, `attribute :deleted, Boolean, default: false`
- Modify: `app/commands/decidim/secure_elections/admin/saves_election_questions.rb` — delete the copy-down loop that broadcasts `question_type` to every question; instead assign each question's own `question_type` from its form
- Delete: `app/views/decidim/secure_elections/admin/elections/_field_templates.html.erb` and any editor-pack code that clones from it
- Delete: any move-up / move-down / remove buttons on the vd-current partials — the divider is the drag surface, and Remove is a single button in the header
- Test: `spec/system/decidim/secure_elections/admin/questions_editor_spec.rb`

**Interfaces:**
- Consumes: `Decidim::Elections::Admin::createEditableForm` (public export from `decidim-forms` pack).
- Consumes: `html5sortable` 0.14.0 (declared in Decidim gem's `packages/core/package.json`).
- Produces: DOM contract per spec §3, verbatim: outer `.questionnaire-questions`, list `.questionnaire-questions-list[data-draggable-table][data-draggable-handle=".card-divider"]`, cards `.card.questionnaire-question` with drag handle icon + `.question--collapse` chevron + `.remove-question` button. `#question-template` and `#response-option-template-<id>` blueprints for cloning.

- [ ] **Step 1: Write the failing spec — three sub-cases**

`spec/system/decidim/secure_elections/admin/questions_editor_spec.rb`:
- clicking `.add-question` appends a new `.card.questionnaire-question` and its `question_type` select defaults to the value the spec's `QuestionForm#question_type` default is set to
- dragging card 2 above card 1 via the `.card-divider` handle, then saving, persists the new position (assert `Election#questions.first.body == "card 2 body"`)
- clicking Remove on a question, then Save, destroys the question row (assert `.count` decrements)

- [ ] **Step 2: Run the spec, watch it fail**

```bash
bundle exec rspec spec/system/decidim/secure_elections/admin/questions_editor_spec.rb
```

- [ ] **Step 3: Add per-question `question_type` on the form + model**

`QuestionForm` gains `attribute :question_type, String, default: "singlechoice"` (keep the vd default value — the form change is only the *location* of the attribute). Validator: `inclusion` in the existing `Decidim::SecureElections::Question::QUESTION_TYPES`.

`ElectionQuestionsForm` loses `attribute :question_type` and `attribute :result_visibility`. `result_visibility` is now on `ElectionForm` (Task 2).

- [ ] **Step 4: Delete the copy-down in the save command**

In `SavesElectionQuestions`, delete the `questions.each { |q| q.question_type = question_type }` loop (spec §3 "Questions rewrite" body). Each question already carries its own `question_type` from its `QuestionForm`.

- [ ] **Step 5: Create the four new partials**

Copy DOM verbatim from spec §3 (`_form.html.erb`, `_question.html.erb`, `_response_option.html.erb`, `_response_option_template.html.erb`). Note the `.form__wrapper` only on the question-card inner wrapper, not the outer.

- [ ] **Step 6: Rewrite `questions/edit.html.erb`**

Frame + tabs (already added in Task 1) + `<%= render "form", form: form_object %>` + sticky Save + the small `.add-question` button at the page bottom **outside** the form.

- [ ] **Step 7: Create the editor pack entry**

```js
// app/packs/src/decidim/secure_elections/admin/questions_editor.js
import createEditableForm from "src/decidim/forms/admin/forms"

document.addEventListener("turbo:load", () => {
  if (document.querySelector(".questionnaire-questions")) {
    createEditableForm()
  }
})
```

Ensure the pack is `append_javascript_pack_tag`-loaded on the questions page.

- [ ] **Step 8: Delete the field templates + vd editor pack code**

```bash
git rm app/views/decidim/secure_elections/admin/elections/_field_templates.html.erb
```

In the vd editor pack (`app/packs/src/decidim/secure_elections/admin/editor.js` or similar), delete the `<template>` cloning, move-up/move-down handlers, and remove-question soft-delete logic — all subsumed by `createEditableForm()`.

- [ ] **Step 9: Run the spec, watch it pass**

```bash
bundle exec rspec spec/system/decidim/secure_elections/admin/questions_editor_spec.rb
bundle exec rspec spec/
```

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "questions: upstream editor with drag-reorder and per-question type

Ports the decidim-forms admin editor conventions: html5sortable on the
.card-divider handle, DynamicFieldsComponent cloning the
<script type='text/template'> blueprint, soft-delete via a hidden
[deleted] Boolean, and the small .add-question button at the page
bottom outside the form. question_type moves from ballot-wide to
per-question — the copy-down loop in SavesElectionQuestions is
deleted. result_visibility moves to the Main form (Task 2 already
landed it there).

Deletes _field_templates.html.erb and the vd editor pack's clone /
move-up-down / soft-delete code that html5sortable +
DynamicFieldsComponent now handle."
```

---

### Task 4: Census rewrite

Manifest selector + inline form partial + preview. Folds the vd `Voters` step in.

**Files:**
- Modify: `app/views/decidim/secure_elections/admin/census/show.html.erb` (or `edit.html.erb` — check current entry point) to become the new frame with the manifest selector at top and the sticky Save on the right
- Create: `app/views/decidim/secure_elections/admin/census/_preview.html.erb`
- Create: `app/views/decidim/secure_elections/admin/censuses/_internal_users_form.html.erb` (vd's single current flow, packaged as the "internal users" manifest)
- Modify: `app/controllers/decidim/secure_elections/admin/census_controller.rb` — the `show` action gains `@census_manifests` and dispatches to the manifest form partial
- Modify: `app/forms/decidim/secure_elections/admin/census_form.rb` — add a `manifest` attribute (defaults to `"internal_users"`)
- Delete: any legacy "Voters" step artefacts, if separate (grep for `voters_controller` / `voters#`)
- Test: `spec/system/decidim/secure_elections/admin/census_spec.rb`

**Interfaces:**
- Produces: `#census-manifest-selector` on the page, `#census-election-form` as the inline form id, `.card-section.census-form.form-defaults.2xl:mr-80` container, sticky Save with `form="census-election-form"`.
- Consumes (from Task 1): tabs partial.

- [ ] **Step 1: Write the failing spec**

`spec/system/decidim/secure_elections/admin/census_spec.rb`:
- page has a `#census-manifest-selector` `<select>` with at least the "internal users" option
- selecting a manifest renders the corresponding inline form under `#census-election-form`
- saving a valid census persists members and shows the preview partial

- [ ] **Step 2: Run it, watch it fail**

```bash
bundle exec rspec spec/system/decidim/secure_elections/admin/census_spec.rb
```

- [ ] **Step 3: Rewrite the census show / edit page**

Copy the page frame from spec §4 — the manifest selector, `.card-section.census-form.form-defaults.2xl:mr-80` container, sticky Save. Split the current census body into the `_internal_users_form` partial and reference it via `election.census.admin_form_partial`.

- [ ] **Step 4: Create the preview partial**

Per spec §4: 5-row `.table-list` with identifier + created_at columns, followed by census size text.

- [ ] **Step 5: Fold the Voters step, if separate**

```bash
grep -rn "voters" app/controllers/decidim/secure_elections/admin/ app/views/decidim/secure_elections/admin/
```
If a separate controller/view exists, delete it and move any voter-specific fields into the `_internal_users_form` partial.

- [ ] **Step 6: Run spec + baseline**

```bash
bundle exec rspec spec/system/decidim/secure_elections/admin/census_spec.rb
bundle exec rspec spec/
```

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "census: manifest selector + inline partial + preview

Rebases the census screen on decidim-elections' shape: a manifest
<select> at the top switches between per-manifest inline form partials,
the current vd flow becomes the 'internal_users' partial, and a
5-row preview partial mirrors upstream's census/_preview. Sticky
'Save and continue' on the right is form-linked to #census-election-form.
The vd Voters step folds in here.

Kept: the census members table CSS refinements
(#js-census-members input widths, per-cell errors, remove-row styling)
because upstream's CSV-upload flow doesn't have the per-row editing
that raises them."
```

---

### Task 5: Dashboard rewrite (absorbs show + monitor + setup)

Single page that branches on `election.published?`. Preserves the current `confirm_irreversible` checkbox + red "Publish on the blockchain" button verbatim, moves them into `dashboard/_publish`. Deletes the standalone `setup/show` view and `monitor` controller; the six `SetupForm` completeness validators stay as server-side guard. Adds the **Start election** button when `manual_start && paused` (assumes SaaS PR has landed — no feature flag).

**Files:**
- Create: `app/controllers/decidim/secure_elections/admin/dashboard_controller.rb` (actions: `show`, `publish`, `unpublish`, `start`; `show` branches on `published?`)
- Create: `app/views/decidim/secure_elections/admin/elections/dashboard.html.erb`
- Create: `app/views/decidim/secure_elections/admin/dashboard/_checklist.html.erb`, `_main.html.erb`, `_questions.html.erb`, `_census.html.erb`, `_publish.html.erb`, `_status.html.erb`, `_calendar.html.erb`, `_results.html.erb`
- Modify: `lib/decidim/secure_elections/admin_engine.rb` routes — add `resource :dashboard, only: [:show]` with `post :publish, delete :unpublish, post :start` members; **remove** `resource :setup` and `resource :monitor`; keep `put :publish, put :unpublish` on the elections member for backwards-compatible index-row wiring but see Task 6 for what actually gets rendered from the row dropdown
- Modify: `app/commands/decidim/secure_elections/admin/publish_election.rb` — payload gains `"paused": true` and `"interruptible": true` when `election.manual_start?`; leave `startDate` omitted when `start_at` blank (already the case)
- Delete: `app/controllers/decidim/secure_elections/admin/setup_controller.rb`, `app/controllers/decidim/secure_elections/admin/monitor_controller.rb`
- Delete: `app/views/decidim/secure_elections/admin/setup/show.html.erb`, `app/views/decidim/secure_elections/admin/monitor/*`
- Delete: `app/commands/decidim/secure_elections/admin/setup_election.rb` (its enqueue-PublishElectionJob behaviour moves into `PublishElection`)
- Modify: `app/forms/decidim/secure_elections/admin/setup_form.rb` — keep as-is; the Dashboard's `publish` action posts a `SetupForm` and reads the checkbox
- Test: `spec/system/decidim/secure_elections/admin/dashboard_spec.rb`

**Interfaces:**
- Consumes: `Election#published?`, `#manual_start?`, `#paused?`, `#*_complete?` predicates (all pre-existing except `paused?`, which returns true when the on-chain status is PAUSED; wire it via the existing status polling client — `api_client/elections.rb`).
- Consumes: `SetupForm#confirm_irreversible` + the six completeness validators (unchanged).
- Consumes: `bulk_set_question_status(status: :READY)` on `api_client/elections.rb:130-136` for the Start button.
- Produces: `dashboard_election_path`, the sticky **Publish on the blockchain** button that submits the SetupForm-shaped payload, the sticky **Start election** button when applicable.

- [ ] **Step 1: Write the failing spec — five sub-cases**

`spec/system/decidim/secure_elections/admin/dashboard_spec.rb`:
- unpublished + all checks passing → sticky "Publish on the blockchain" button present, disabled until `#setup_confirm_irreversible` is ticked
- unpublished + one check failing (e.g. no questions) → checklist row shows error-warning-line icon + "fix it" link to `edit_questions_election_path`; Publish button disabled
- unpublished, tick checkbox and submit → `PublishElectionJob` enqueued
- published + `manual_start: true` + status `paused` → "Start election" button visible
- published + status `ongoing` → live-refresh monitor markup with `#js-vocdoni-monitor` present

- [ ] **Step 2: Run it, watch it fail**

```bash
bundle exec rspec spec/system/decidim/secure_elections/admin/dashboard_spec.rb
```

- [ ] **Step 3: Add routes**

```ruby
# admin_engine.rb
resource :dashboard, only: [:show], controller: "dashboard" do
  post :publish
  delete :unpublish
  post :start
end
# Remove: resource :setup, resource :monitor
```

- [ ] **Step 4: Create the controller + view + all eight partials**

`DashboardController#show` sets `@form = form(SetupForm).instance(election:)` when unpublished. Branches in the view on `election.published?`. Partials per spec §5 (verbatim class lists, ids, and copy).

`_publish.html.erb` contains exactly the current `setup/show.html.erb` `<div id="js-vocdoni-setup">` block — checkbox + red button — moved verbatim.

`_results.html.erb` contains the current `monitor` markup — `#js-vocdoni-monitor` + `#js-vocdoni-monitor-results` + `data-status-url` / `data-refresh-url` — moved verbatim.

- [ ] **Step 5: Wire the Publish payload for `manual_start`**

In `PublishElection` command (`app/commands/decidim/secure_elections/admin/publish_election.rb`), when `election.manual_start?`, add `"paused": true` and force `"interruptible": true` to the SaaS payload.

- [ ] **Step 6: Wire the Start button**

`DashboardController#start` calls `api_client.bulk_set_question_status(election, status: :READY)` and redirects back to the dashboard. Route: `post :start`.

- [ ] **Step 7: Delete the setup / monitor controllers and views**

```bash
git rm app/controllers/decidim/secure_elections/admin/setup_controller.rb \
       app/controllers/decidim/secure_elections/admin/monitor_controller.rb \
       app/views/decidim/secure_elections/admin/setup/show.html.erb \
       app/commands/decidim/secure_elections/admin/setup_election.rb
git rm -r app/views/decidim/secure_elections/admin/monitor
```

- [ ] **Step 8: Run spec + baseline**

```bash
bundle exec rspec spec/system/decidim/secure_elections/admin/dashboard_spec.rb
bundle exec rspec spec/
```

Delete the old `setup_spec.rb` and `monitor_spec.rb` — the Dashboard spec covers both.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "dashboard: single branching page absorbs setup + monitor + show

Adds DashboardController + dashboard.html.erb that branches on
election.published?. Unpublished: completeness checklist +
read-only preview cards + sticky confirm_irreversible checkbox
followed by the red 'Publish on the blockchain' button — the current
vd Publish flow preserved verbatim, only its home moves from
setup/show into dashboard/_publish. Published: status + calendar
(with 'Start election' when manual_start && paused) + live-refresh
results using the current vd #js-vocdoni-monitor markup.

Deletes SetupController, MonitorController, setup/show.html.erb, and
monitor/*; SetupForm stays because its six completeness validators are
still the server-side guard for publish. PublishElection command
gains 'paused' + 'interruptible' when manual_start is set (SaaS
InitialStatus PR is assumed merged)."
```

---

### Task 6: Elections index dropdown

Adopt upstream `resource_action_dropdown`. Deliberately **do not** surface Publish from the row — Publish routes through the Dashboard.

**Files:**
- Modify: `app/views/decidim/secure_elections/admin/elections/index.html.erb` (or the `_actions.html.erb` partial it renders)
- Test: `spec/system/decidim/secure_elections/admin/elections_index_spec.rb`

**Interfaces:**
- Produces: per-row `<ul class="dropdown dropdown__action">` with Edit / Unpublish (published only) / Preview (published only) / Move to trash. No Publish item.
- Consumes: upstream `resource_action_dropdown` helper (available via Decidim admin).

- [ ] **Step 1: Write the failing spec**

`spec/system/decidim/secure_elections/admin/elections_index_spec.rb`:
- on an unpublished election row, dropdown has Edit and Move to trash — no Publish
- on a published election row, dropdown has Edit, Unpublish, Preview, Move to trash
- `soft_delete` link uses `data-method="patch"` and has `data-confirm`

- [ ] **Step 2: Run it, watch it fail**

- [ ] **Step 3: Replace the current row action markup**

Copy the dropdown block verbatim from spec §6 (elections index) — including the commented-out Publish item explaining why it's not surfaced. `soft_delete` uses `method: :patch`.

- [ ] **Step 4: Run spec + baseline**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "index: per-row action dropdown mirrors upstream

Uses resource_action_dropdown with Edit / Unpublish / Preview / Move
to trash. Publish is deliberately not exposed from the row — it lives
on the Dashboard where the confirm_irreversible checkbox is. Kept a
commented-out Publish item for future porters. soft_delete uses PATCH,
matching both upstream and current vd."
```

---

### Task 7: i18n cleanup + sweep

Rename orphaned keys, add the new tab labels, run `bundle exec i18n-tasks` to catch dead / missing strings.

**Files:**
- Modify: `config/locales/en.yml` (and every sibling locale for missing/unused keys — leave English fallback, do not hand-translate)
- Modify: any `t(".…")` sites that fell out of sync during the rewrite

**Interfaces:** none — cleanup only.

- [ ] **Step 1: List orphans**

```bash
bundle exec i18n-tasks unused
bundle exec i18n-tasks missing
```

- [ ] **Step 2: Delete orphaned keys**

Every key under `decidim.secure_elections.admin.setup.*`, `decidim.secure_elections.admin.calendar.*`, `decidim.secure_elections.admin.monitor.*`, `.editor.start_immediately*` — delete unless still referenced.

- [ ] **Step 3: Add missing keys**

New keys the rewrite introduced:
- `decidim.secure_elections.admin.menu.main`, `.questions`, `.census`, `.dashboard`
- `decidim.secure_elections.admin.elections.form.basic_info`, `.calendar`, `.results_availability_title`, `.save_and_continue`
- `decidim.secure_elections.admin.elections.editor.manual_start` + `.manual_start_help`
- `decidim.secure_elections.admin.results_availability.real_time` + `.real_time_help`, `.after_end` + `.after_end_help`
- `decidim.secure_elections.admin.dashboard.checklist.*`, `.publish.confirm_irreversible_label`, `.publish.publish_button`
- Fill each with real English copy (see spec §"Dashboard" and §"Main" for user-facing labels).

- [ ] **Step 4: Re-run i18n-tasks and the full suite**

```bash
bundle exec i18n-tasks unused
bundle exec i18n-tasks missing
bundle exec rspec spec/
```
Expected: all clean.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "i18n: sweep after the upstream-alignment rewrite

Removes orphaned setup/calendar/monitor/start_immediately keys and
adds the labels the four-tab strip, three-accordion Main, and
Dashboard need. Non-en locales are left with the English fallback;
translation is a follow-up."
```

---

## Self-Review

**Spec coverage:**
- §Motivation → covered by Task 1's frame change (the tab strip is the visible signal).
- §Confirmed decisions 1–4 (drop autosave, one PR, rename, drop wizard) → Tasks 2 + 1.
- §Target IA (four tabs, order) → Task 1.
- §Section 1 Frame → Task 1 (partial) + reinforced in every subsequent task's view.
- §Section 2 Main → Task 2.
- §Section 3 Questions → Task 3.
- §Section 4 Census → Task 4.
- §Section 5 Dashboard → Task 5.
- §Section 6 Elections index → Task 6.
- §Constraints preserved → covered implicitly: `per_question` excluded (Task 2 enum), autosave dropped (Task 2), unpublished Dashboard is vd-net-new (Task 5), checkbox acknowledgement preserved (Task 5), live monitor kept (Task 5), borderless-title dropped (Task 2).
- §Protocol support for manual_start → Task 5 (publish payload) + Task 2 (form/column). SaaS-side assumed merged (per user note).
- §Naming gotcha → Task 2 (delete old method first, then wire new column).
- §Rename plan → Task 2.
- §Migration plan → this plan mirrors it 1:1.
- §Testing plan → each Task has the corresponding system spec.

**Placeholder scan:** ran a mental grep — no "TBD" or "handle edge cases"; each step has either the exact command or the exact file to touch. The two places I lean hardest on the spec (`_form.html.erb` accordion contract in Task 2 Step 5, question partials in Task 3 Step 5) reference spec §2 / §3 which contain verbatim ERB. The alternative — duplicating 120 lines of ERB across spec + plan — would rot the pair.

**Type / name consistency:** menu key `:admin_secure_elections_menu` is used identically in Task 1 (registration) and every subsequent task that mentions it. `dashboard_election_path` is stubbed in Task 1 and wired in Task 5. `SetupForm` is preserved (Task 5); `SetupElection` command is deleted (Task 5). `PublishElection` command is what actually enqueues the job after Task 5. `Election#paused?` is stubbed in Task 2 and wired in Task 5. All consistent.

**Gap:** None found on re-read.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-09-04-align-with-upstream-elections-implementation.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
