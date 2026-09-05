# Align `decidim-secure_elections` admin UI with upstream `decidim-elections`

Status: draft for review
Date: 2026-09-04
Owners: Aulet (UX), vd engineering

## Motivation

The admin UI in `decidim-secure_elections` was ported from `saas-backend`, not
from Decidim's own `decidim-elections`. The two live inside the same admin
panel, so an admin that has just come from the participatory-processes side of
Decidim reads them as two different applications: different frame, different
button shapes, different way of adding a question, different way of publishing.
Aulet's review round after the first pass of copy/spacing fixes concluded that
the divergence is not something small tweaks will close — the UX has to be
re-based on upstream. This spec is that re-base.

The stance is: **be identical to upstream except where the underlying protocol
makes it impossible.** Blockchain-specific concerns (on-chain publish
transaction and its acknowledgement, monitor / live vote count) stay as
vd-only surfaces that adopt upstream's visual language; everything else
gets the upstream layout, buttons, and flow.

## Scope

In scope:

- Elections editor across all steps (Main, Questions, Census, Publish,
  Monitor — the last two collapsing into the Dashboard tab).
- Step navigation frame and the elections index row actions.
- Drop the wizard/step-progression pattern; adopt upstream's persistent
  horizontal tab strip.
- Rename `start_immediately` → `manual_start` (semantic invert included).
  Database is dropped: no production data to migrate.

Out of scope:

- Public voter-facing pages.
- Ballot cryptography and the ballot builder itself.
- The census import / CSV pipeline internals (only the wrapper screen changes).
- Localisation copy beyond the strings that move or are renamed by this work.

## Confirmed decisions (from the brainstorm)

1. **Drop autosave.** The 30-second background POST on `Details` and the
   status-line prose it announces are removed. Rationale: upstream saves only
   on explicit click, and Aulet's Q&A found no user need for autosave; keeping
   it doubled the surface area of every rebuild.
2. **One PR, not phased.** The rewrite ships as a single PR against
   `feedback/aulet-round-1`. Rationale: the pages share the same frame, tabs,
   and JS bootstrap; splitting produced churn and half-migrated states in the
   sketches.
3. **Rename `start_immediately` → `manual_start`.** No migration: the DB is
   dropped, there is no production data. Rationale: name alignment with
   upstream is worth more than back-compat when back-compat costs nothing.
   Semantic inverts (`start_immediately = true` ↔ `manual_start = false`).
4. **Wizard progression is dropped.** Replaced by the upstream persistent
   horizontal tab strip.

## Target information architecture

Same four tabs and same order as upstream (verified live on
`try.decidim.org`, `_tabs_menu.html.erb` + `admin_tabs` registry):

```
Main │ Questions │ Census │ Dashboard
```

The first tab is labelled **Main** (upstream i18n label) rather than
"Details" — that's what a fresh admin sees on the live site. The order
also happens to match vd's current wizard, so no muscle-memory break for
existing admins.

- **Main** — merges vd's current `elections#new`/`edit` + `calendar`
  step + a new results-availability picker. Three accordion cards inside one
  form. (Referred to as "Main" throughout the rest of this spec, matching
  the upstream tab label.)
- **Questions** — full rewrite to upstream's editor. `question_type` moves
  from ballot-wide to per-question; the "This applies to every question of
  this election" copy is deleted.
- **Census** — upstream layout (manifest selector + inline form + preview).
  The current vd `census` and `voters` are consolidated here.
- **Dashboard** — single page branching on `published?`. Before publish
  it hosts the read-only preview, the vd completeness checklist, and the
  Publish action (this absorbs vd's current step 5 in the wizard, which
  the nav labels **"Publish"** — the `SetupController` name is a code
  detail, not the user-facing label). After publish it hosts the status
  card, calendar (with **Start election** when `manual_start`), results,
  and the live monitor. **Note the upstream deviation:** upstream
  disables its Dashboard tab pre-publish and puts Publish (with no
  confirmation) in the index row dropdown; vd instead keeps the tab
  always live, uses the checklist + `confirm_irreversible` checkbox for
  acknowledgement, and does not surface Publish from the index row. See
  Section 5 for the full rationale.

`admin_tabs(:admin_secure_elections_menu)` is registered in the module's
initializer with the four entries above.

## Screen-by-screen design

### 1. Frame

Every editor screen adopts the upstream frame:

```
<div class="item__edit item__edit-1col">
  <div class="item__edit-form">                <!-- add `2xl:mr-80` only on screens with a sticky column -->
    ...form...
  </div>
  <div class="item__edit-sticky">
    <div class="item__edit-sticky-container">
      <%= button_tag t(".save_and_continue"), form: "<form-id>",
                     class: "button button__sm button__secondary" %>
    </div>
  </div>
</div>
```

Notes verified against live upstream:

- The `2xl:mr-80` margin is **per-screen**, not a universal frame class.
  Live upstream applies it on the published Dashboard's `.item__edit-form`
  and on Census's inner card (`.card-section.census-form.2xl:mr-80`), but
  **not** on the Main edit page (`/elections/15/edit` renders plain
  `<div class="item__edit-form">`).
- Sticky button label upstream is **"Save and continue"** (not "Save"),
  and the Main form id is `basic-election-form-edit`. Use these when
  rendering, so muscle memory transfers from decidim-elections.

The horizontal tab strip renders above the form column:

```
<%= render "decidim/secure_elections/admin/elections/tabs_menu" %>
```

`_tabs_menu.html.erb` mirrors upstream — a `.main-tabs-menu` with
`admin_tabs(:admin_secure_elections_menu).render` inside
`.main-tabs-menu__tabs`. The vd-specific `.vocdoni-step-nav` and the
wizard-style step footer partial are deleted.

### 2. Main

Merges the current Details form + the Schedule step + a new results
picker into one form with three collapsible accordion cards.

Cards, in order:

1. **Basic info** — translated title, translated description, optional
   `stream_uri`. Title uses the standard upstream label-above-input
   treatment (the vd `.vocdoni-editor__title` borderless-heading carve-out
   is dropped, both here and on question cards — see the Questions section).
2. **Calendar** — start / end datetime pickers plus a `manual_start`
   checkbox. Two datetime inputs sit side-by-side on desktop
   (`.md:flex.w-100`) and stack on mobile. Semantics match upstream:
   - `manual_start = false`, `start_at` blank → election opens the moment
     it is published (this is vd's current default).
   - `manual_start = false`, `start_at` set → election opens at that
     scheduled time.
   - `manual_start = true` → election is published in a paused state and
     opens only when the admin clicks **Start election** on the Dashboard.
     `start_at` is not required in this mode (and is ignored).
   The chain side of this is resolved (see "Protocol support for
   `manual_start`" below); this depends on a small SaaS patch landing first.
3. **Results availability** — radio group. Options: `real_time`, `after_end`.
   `per_question` is deliberately excluded because vd's protocol does not
   support it (see Constraints preserved).

Each card, matching live upstream (`try.decidim.org/…/elections/15/edit`,
`#accordion-basic`):

```
<div class="card form-<name>" data-controller="accordion" data-component="accordion"
     id="accordion-<name>" role="presentation">
  <div class="card-divider">
    <button type="button" class="card-divider-button"
            data-controls="panel-<name>" data-open="true"
            role="button" aria-controls="panel-<name>" aria-expanded="true">
      <%= icon "arrow-right-s-line", class: "flex-none" %>
      <h2 class="card-title"><%= t(".<name>") %></h2>
    </button>
  </div>
  <div id="panel-<name>" role="region" tabindex="-1" aria-hidden="false">
    ...body content...  <!-- NO .card-section wrapper on the panel; NO data-accordion-target -->
  </div>
</div>
```

Key details easy to get wrong (verified against live DOM):

- `.card-divider-button` is on the `<button>`, **not** compounded onto
  `.card-divider`.
- The `<button>` wraps the `<h2>`, with the chevron icon **before** the
  title inside the button. The chevron is `arrow-right-s-line` (rotates
  visually via CSS when open), not `arrow-down-s-line`.
- The panel id prefix is `panel-`, e.g. `panel-basic`, `panel-calendar`,
  `panel-results`. `data-controls` on the button points to that id.
- No `data-action="click->accordion#toggle"` and no
  `data-accordion-target="content"` — the Stimulus accordion controller
  uses `data-controls` + `data-open` alone.
- The body panel is a plain `<div id="panel-<name>" role="region">`
  without a `.card-section` inner wrapper. Inputs sit directly in it,
  each wrapped by the form builder as usual.

Sticky **"Save and continue"** button at the right; form id
`basic-election-form-edit` (mirrors upstream). The vd-specific
`calendar/edit.html.erb`, its controller and its form (currently a
separate step) are deleted; `ElectionCalendarForm`'s attributes fold
into `ElectionForm`.

Autosave wiring on `_details_fields.html.erb` (the `data-autosave-*`
attributes, the `[data-vocdoni-status]` line, the JS pack side that reads
them) is removed.

### 3. Questions

Full rewrite. DOM contract, matching live upstream:

```
<div class="questionnaire-questions">           <!-- no .form__wrapper here on upstream -->
  <div class="text-right my-4">
    <button class="collapse-all">Collapse</button> |
    <button class="expand-all">Expand</button>
  </div>

  <script type="text/template" id="question-template">
    <!-- one blank question card, rendered via fields_for on a blank_question -->
  </script>

  <div class="questionnaire-questions-list flex flex-col py-6 gap-6"
       data-draggable-table
       data-draggable-handle=".card-divider"
       id="questionnaire-questions-list">
    <!-- one .card.questionnaire-question per question -->
  </div>
</div>

<button class="button button__sm button__transparent-secondary add-question mt-1">
  Add question
</button>
```

(`.form__wrapper` on upstream is applied to **each question card's
inner wrapper** — `<div class="form__wrapper" data-controller="accordion">`
inside `.card.questionnaire-question` — not to the outer
`.questionnaire-questions` container.)

Each question card:

```
<div class="card questionnaire-question" id="accordion-<id>-field">
  <div class="form__wrapper" data-controller="accordion">
    <div class="card-divider">                    <!-- entire divider is the drag surface -->
      <h2 class="card-title flex items-center">
        <span>
          <%= icon "draggable", class: "dragger hover:cursor-grab" %>
          <%= dynamic_title(...) %>
        </span>
        <span class="ml-auto flex flex-row-reverse items-center gap-2">
          <button class="question--collapse" data-controls="panel-<id>-question-card">
            <span class="icon-collapse"><%= icon "arrow-up-s-line" %></span>
            <span class="icon-expand"><%= icon "arrow-down-s-line" %></span>
          </button>
          <button class="button button__xs button__transparent-secondary small alert remove-question button--title">
            <%= icon "delete-bin-line" %>
            <span class="hidden md:block">Remove</span>
          </button>
        </span>
      </h2>
    </div>
    <div id="panel-<id>-question-card" class="mt-4 card-section collapsible">
      <%= form.translated :text_field, :body,        label: "Statement" %>
      <%= form.translated :editor,     :description, label: "Description" %>
      <%= form.select     :question_type, ... %>     <!-- per-question -->

      <%= form.hidden_field :id if question.persisted? %>
      <%= form.hidden_field :deleted %>

      <div class="questionnaire-question-response-options"
           data-template="#response-option-template-<id>">
        <div class="questionnaire-question-response-options-list">
          <!-- one .card.questionnaire-question-response-option per option -->
        </div>
        <button class="button button__sm button__transparent-secondary add-response-option">
          Add response option
        </button>
      </div>

      <%= form.select :max_choices, (2..question.number_of_options), include_blank: "Any" %>
    </div>
  </div>
</div>
```

Each response option is a **full card** (not a compact row), no drag handle
(options are not reorderable upstream; vd will match):

```
<div class="card questionnaire-question-response-option mx-4 my-8">
  <div class="card-divider">
    <h2 class="card-title mb-2">
      <span>Response option</span>
      <button class="button button__xs button__transparent-secondary small alert remove-response-option button--title" style="display:none">
        <%= icon "delete-bin-line" %> Remove
      </button>
    </h2>
  </div>
  <div class="card-section">
    <%= form.translated :text_field, :body, label: "Statement" %>
  </div>
  <%= form.hidden_field :id if response_option.persisted? %>
  <%= form.hidden_field :deleted %>
</div>
```

JS wiring — `createEditableForm()` per upstream, with two collaborators:

- `html5sortable` 0.14.0 for reorder. `handle: ".card-divider"` (entire
  header is grabbable, not just the drag icon).
- `DynamicFieldsComponent` (jQuery, 236 LOC in `decidim-admin`) for clone /
  remove / renumber of the `<script type="text/template">` blueprints.

Both are already available to vd via the Decidim gem — no new packages.

Soft delete: `Remove` sets the hidden `deleted` boolean and hides the DOM
node; the row is submitted with the form; `UpdateElectionQuestions` destroys
matching rows on save. No per-row DELETE request.

`add-question` button is small (`button__sm button__transparent-secondary`)
and lives at the bottom of the page, **outside** the form — copies upstream
verbatim. The current full-width "Add question" button is removed.

`question_type` moves to per-question. `ElectionQuestionsForm` loses its
ballot-wide `attribute :question_type`; the copy-down loop in
`SavesElectionQuestions` that assigns `question_type` from the form to every
question is removed. The "This applies to every question of this election.
Each question still becomes its own election on the blockchain." help copy
is deleted. Each per-question select carries its own help copy.

`result_visibility` (currently ballot-wide on this form) moves to the Details
form (see Section 2, results card). The Questions form no longer touches
`secret_until_the_end`.

The existing vd `_field_templates.html.erb` (with `<template>` elements
cloned by the vd editor pack) is replaced by the upstream
`<script type="text/template">` pattern that `DynamicFieldsComponent`
expects. The vd editor pack's clone / add / remove / renumber /
move-up/move-down / autosave code is deleted with it.

### 4. Census

Upstream layout:

```
<%= render "decidim/secure_elections/admin/elections/tabs_menu" %>

<div class="form-defaults my-8 flex justify-end">
  <%= select_tag "census_manifest", ..., id: "census-manifest-selector" %>
</div>

<% if election.census_ready? %>
  <%= cell "decidim/announcement", "...", callout_class: "success" %>
<% end %>

<div class="card-section census-form form-defaults 2xl:mr-80">
  <%= decidim_form_for(@form, url: ..., html: { id: "census-election-form" }) do |f| %>
    <%= render partial: election.census.admin_form_partial, locals: { form: f } %>
  <% end %>
  <%= render "decidim/secure_elections/admin/census/preview", locals: { election: } if preview_users(election).present? %>
</div>

<div class="item__edit-sticky">
  <div class="item__edit-sticky-container">
    <%= button_tag "Save", form: "census-election-form",
                   class: "button button__sm button__secondary #{"hide" unless election.census}" %>
  </div>
</div>
```

Sticky Save at the right, form-linked. The manifest selector switches (via
Turbo) between per-manifest inline form partials (`_internal_users_form`,
`_token_csv_form`, `_dataset_csv_form`, ...). vd today has a single flow;
this becomes the "internal users" partial in the new structure, and future
manifests plug in the same way.

The current vd `Voters` step is folded in here (there is no separate Voters
screen upstream). `Census` in vd today is a subset of what upstream calls
Census; the two merge under the upstream name.

Preview partial (`_preview.html.erb`): first 5 rows in a `.table-list` with
identifier + created_at columns, followed by census size text.

The census members table refinements from `editor.scss` (`#js-census-members`
input widths, per-cell errors, remove-row styling) are kept — they solve
problems upstream doesn't have because upstream's flow is CSV upload not
per-row editing.

### 5. Dashboard (replaces `show` + `monitor` + `setup`)

Single page that branches on `election.published?`. Every route that used
to hit `setup/show`, `elections/show` or `monitor/show` now lands here.
The controller/routes in vd today are `SetupController` at path `/setup`
— code names stay; the **user-facing label** in the nav becomes
`Dashboard` (vd today labels this step **"Publish"**, not the misleading
"Trusted setup" that appears in some internal notes).

**Upstream carve-out — the unpublished half of this page is vd-net-new.**
Live upstream `try.decidim.org` disables the Dashboard tab entirely
until the election is published (renders `<span
class="sidebar-menu__item-disabled">Dashboard</span>`; a direct fetch of
`/dashboard` 302s out). Upstream's Publish action lives only in the row
dropdown of the elections index, and ships with **no confirmation
dialog at all** (`<a data-method="put" href="…/publish">` — no
`data-confirm`). We are deliberately not copying that: an irreversible
on-chain write with zero confirmation is a bad safety story for vd's
users, and we already have a working checklist and acknowledgement to
build on. The unpublished-Dashboard flow below is a vd-only design
that reuses upstream's card/frame vocabulary but is not a mirror of
any upstream screen.

**Unpublished** (pre-publish preview, vd-only):

- `dashboard/_checklist` — the completeness checks that vd already
  computes (`details_complete?`, `questions_complete?`, `census_complete?`,
  `calendar_complete?`, `module_configured?`), each row a check-line or
  error-warning-line icon with a "fix it" link back to the failing tab.
  Rendered as a `.card` at the top of the page. Gives the admin an
  early, page-level answer to "why is Publish disabled" instead of a
  validation error after clicking.
- `dashboard/_main` — read-only summary card of Details (title, dates,
  `results_availability`, `manual_start` if set). Pencil-edit link in the
  card divider back to `edit_election_path`.
- `dashboard/_questions` — first N questions as read-only cards showing
  statement + question type + option count. Pencil link to
  `edit_questions_election_path`; "…and more" note beyond N.
- `dashboard/_census` — reuses the `census/_preview` partial.
- Sticky action (`.item__edit-sticky`): the current vd Publish flow is
  preserved verbatim — a `confirm_irreversible` checkbox with the
  irreversibility copy, then a red **"Publish on the blockchain"** submit
  button (`.button.button__sm.alert`). Both the checkbox validation
  (`SetupForm#confirm_irreversible`) and the button disable-until-ticked
  stay. What changes is only where it lives: the standalone `setup/show`
  page is deleted, its markup moves into `dashboard/_publish` and renders
  inside the sticky column on the unpublished Dashboard. All existing
  server-side checklists (`election_is_off_chain`,
  `details_are_complete`, `questions_are_complete`,
  `census_is_configured`, `calendar_is_complete`, `module_is_configured`)
  stay as second-line defence in `SetupForm`, unchanged.

**Publishing** (transient, after the click but before the on-chain tx
confirms): show a `warning` announcement ("in progress") in place of the
Publish button — the same behaviour `setup/show` has today via the
`publishing` state on the election. `dashboard/_status` renders the
in-flight state so the admin sees the job is running.

**Published**:

- `dashboard/_status` — status badge, participation count.
- `dashboard/_calendar` — start / end dates, plus **Start election**
  button when `election.manual_start? && election.paused?`. That button
  calls `bulk_set_question_status(status: :READY)` — the existing vd
  client, see `Naming gotcha` in Protocol support for `manual_start`.
- `dashboard/_results` — the existing vd `#js-vocdoni-monitor` and
  `#js-vocdoni-monitor-results` live-refresh markup is preserved
  verbatim: `data-status-url` / `data-refresh-url` polling attributes,
  the four `data-refresh-*-label` strings, the `data-just-updated`
  visual highlight and the CSS spinner all stay. Upstream's equivalent
  attribute for its Turbo-based updates is `data-results-live-update`
  (present on `try.decidim.org` `/elections/4/dashboard`), but rewriting
  vd's polling to Turbo is out of scope here — the marker used stays
  vd's current one. Underneath vd's aggregate results card, per-question
  result cards (`.card.mb-4` per question) mirror upstream's Dashboard
  layout.
- Unpublish action (already exists).

The current `elections#show`, `setup#show`, `setup#create` and
`monitor#show` all fold into this page. The stand-alone `setup/show`
view is deleted (its markup moves into `dashboard/_publish`); the
`SetupController` action set + routes shrink to only what the Dashboard
needs; `SetupForm` stays because the acknowledgement checkbox + the
six server-side completeness validators are still the guard for the
publish action; `SetupElection` becomes what the Publish button submits
to (or its enqueue-`PublishElectionJob` behaviour moves into vd's
existing `PublishElection` command at
`app/commands/decidim/secure_elections/admin/publish_election.rb`, and
`SetupElection` is deleted). The completeness predicates
(`details_complete?` etc.) stay on `Election`; they feed both the
checklist partial and `SetupForm`'s server-side validators.

### 6. Elections index

Upstream index frame with a per-row action dropdown, matching live
upstream behaviour verbatim except where noted:

```
<%= render "decidim/admin/components/resource_action_dropdown", resource: election do |actions| %>
  <%= actions.item :edit,        edit_election_path(election),        if: allowed_to?(:update, :election, election:) %>

  <%# Publish: upstream ships with NO confirm dialog. vd keeps its own
      confirm_irreversible checkbox on the unpublished Dashboard instead,
      so we deliberately do NOT expose Publish from the index row —
      admins go through the Dashboard where the checklist and
      acknowledgement live. Left here as a comment for anyone porting
      upstream code verbatim.
  <%= actions.item :publish, publish_election_path(election), method: :put,
                             if: allowed_to?(:publish, :election, election:) && !election.published? %>
  %>

  <%= actions.item :unpublish,   unpublish_election_path(election),   method: :delete,
                                 confirm: t(".unpublish_confirm"),
                                 if: allowed_to?(:unpublish, :election, election:) && election.published? %>
  <%= actions.item :preview,     election_url(election),              target: :blank, if: election.published? %>
  <%= actions.item :soft_delete, soft_delete_election_path(election), method: :patch,
                                 confirm: t(".soft_delete_confirm"),
                                 if: allowed_to?(:soft_delete, :election, election:) %>
<% end %>
```

Details verified against live upstream:

- Publish upstream is `data-method="put"` with **no** `data-confirm`
  attribute. We keep it out of the row dropdown entirely (Publish routes
  through the Dashboard for the reasons above).
- `soft_delete` on both upstream and vd today uses `data-method="patch"`,
  not POST. Preserve that.
- Only `soft_delete` (and, in the published state, `unpublish`) carry
  `data-confirm`.

Clicking the title in a row goes to `dashboard_election_path` (was
`show`).

## Constraints preserved (vd-specific carve-outs from upstream)

These deviations are deliberate:

- **No `results_availability = per_question`.** vd's protocol only supports
  ballot-wide reveal (real-time or after-end). The radio group excludes the
  option; the form validator rejects it; the model enum lists only the two
  values.
- **No autosave on Details.** Explicitly dropped per the brainstorm.
- **Drafts still open** for editing after any structural change until
  publish. Preserved; the existing `editable?` gates on the forms carry over
  unchanged.
- **Unpublished Dashboard is vd-net-new.** Upstream disables the
  Dashboard tab until the election is published and puts Publish in the
  index row dropdown with no confirm. vd instead renders a full
  pre-publish preview (checklist + summary cards + confirm-and-publish
  action) inside the Dashboard tab, so the admin has one place to review
  and commit an on-chain write. This is a deliberate deviation, not a
  mirror of upstream.
- **Publish acknowledgement stays as `confirm_irreversible` checkbox +
  red "Publish on the blockchain" button.** vd's current pattern is
  preserved verbatim; the standalone `/setup` page is deleted and the
  markup moves into the Dashboard's sticky column. Upstream ships
  Publish with no confirmation at all, which is not acceptable for an
  irreversible on-chain write.
- **Live monitor on Dashboard.** vd polls the vochain for live counts; the
  existing `#js-vocdoni-monitor` markup and its live-update CSS are kept,
  now inside the Dashboard results card.
- **Borderless title carve-out is dropped.** The
  `.vocdoni-editor__title` and `.vocdoni-question__title` treatments are
  removed; title inputs render the standard upstream way (label above,
  bordered input). One less vd carve-out to maintain.

## Protocol support for `manual_start`

Investigated (`/tmp/aulet-diag/manual-start-feasibility.md`). Summary:

- **vocdoni-node accepts `NewProcess` transactions with
  `Status: PAUSED`.** Born-paused is a first-class protocol feature:
  `vocdoni-node/vochain/transaction/election_tx.go:46-48` whitelists both
  `READY` and `PAUSED` as valid initial statuses. `Process.Mode.Interruptible`
  must be `true` in this mode so the admin can later unpause; vd already
  threads `Interruptible`.
- **SaaS backend currently hardcodes `Status: READY`.**
  `saas-backend/account/process.go:117-163` builds the tx with
  `models.ProcessStatus_READY` and `NewProcessParams` has no
  `InitialStatus` knob. Fix is small (~50 LOC, one PR): add
  `InitialStatus` to `NewProcessParams`, thread through
  `db.ElectionParams` and the create-process handler, regenerate swagger.
- **`StartTime` is orthogonal.** It is a hard clock gate that auto-opens
  the process at the timestamp; it cannot substitute for `manual_start`,
  which must wait for an admin action of unknown timing.

**Chosen path (Path A):** land the SaaS patch first, then vd. The publish
job's payload gains `paused: true` when `manual_start` is set and forces
`Interruptible: true`. The Dashboard's **Start election** button calls the
existing `bulk_set_question_status(status: :READY)` client (`app/services/
decidim/secure_elections/api_client/elections.rb:130-136`) — no new client
method needed.

**Path B (publish-then-pause) is rejected for production** — a ~1–2 block
race window between publish confirmation and pause confirmation would let
votes land on a supposedly paused election, and either tx can fail
independently. Kept in the back pocket only as an emergency fallback if the
SaaS PR is delayed.

**Rollout note:** the vd PR is blocked on the SaaS PR shipping first.
No feature flag on the vd side — once SaaS is deployed with
`InitialStatus` exposed, vd merges and deploys. Rationale: keeping a
temporary gate in the vd codebase for a coordination window we control
is more code than the coordination costs, and the SaaS PR is small
(~50 LOC).

### Naming gotcha — the existing `manual_start?` in vd means the opposite

`app/models/decidim/secure_elections/election.rb:161` currently defines:

```ruby
def manual_start?
  start_time.blank?
end
```

That reads "start_time is not scheduled, therefore the admin will trigger
the start by publishing." In upstream's vocabulary that is
`start_immediately` — the *opposite* of `manual_start`. The rename is
therefore a real refactor, not a symbol swap: every call site that reads
`manual_start?` today has to be flipped. The safest sequence is:

1. Delete the existing method first (it has no upstream-equivalent
   meaning under the new semantics).
2. Add the new `manual_start` column and form attribute with upstream
   semantics.
3. Update every call site by reading the new attribute directly, and
   express the "open-on-publish" branch as `manual_start? == false &&
   start_at.blank?` where needed.

This ordering forces the compiler / tests to point at every existing
`manual_start?` call rather than silently flipping meaning.

## Open questions

### 1. `admin_tabs` registration key

Upstream registers the menu as `:admin_elections_menu` in an initializer.
vd already has an initializer surface; the new registration key will be
`:admin_secure_elections_menu`. If the module has a helper that shares the
elections menu with any other component, this rename may need coordination.
Assumed low-risk (grep suggests no such sharing today), but flagging.

## Rename plan: `start_immediately` → `manual_start`

- Form: `ElectionCalendarForm` merges into `ElectionForm`. `attribute
  :start_immediately, Boolean, default: true` becomes `attribute
  :manual_start, Boolean, default: false`. New validation:
  - `start_at` is optional (was required when `!start_immediately?`).
    Both `manual_start = true` and `manual_start = false, start_at blank`
    are valid — they mean "born paused" and "opens on publish"
    respectively.
  - When `start_at` is present, `end_at` must be after it.
- Field name on the form: `start_time` → `start_at`, `end_time` → `end_at`
  (matches upstream and the datetime helper's Rails convention).
- View: the calendar checkbox is a `manual_start` toggle. Its label and
  help text change (i18n keys renamed under
  `decidim.secure_elections.admin.elections.editor`).
- Model column: `elections.start_time` → `elections.start_at`,
  `elections.end_time` → `elections.end_at`, add `manual_start` boolean.
  **DB is dropped** — no migration file, schema is regenerated. The seeds
  file and factories are updated in the same commit.
- Publish job: `PublishElectionJob` payload gains `"paused": true` and
  forces `"interruptible": true` when `election.manual_start?`. `startDate`
  is omitted when `start_at` is blank (already the case today).
- Dashboard: **Start election** button visible when
  `election.published? && election.manual_start? && election.paused?`.
  It calls `bulk_set_question_status(status: :READY)` and refreshes the
  status card via the existing monitor plumbing.
- All references in commands, GraphQL types, tests, seeds, and locales are
  renamed in one PR.

Semantic invert reminder: the old `start_immediately = true` maps to the
new `manual_start = false && start_at.blank?`. The old `manual_start?`
method on `Election` (which meant "start_time is blank") is deleted at the
start of the rewrite — see the "Naming gotcha" section above.

## Migration plan (implementation ordering)

Prerequisite: the small SaaS PR that adds `InitialStatus` to
`NewProcessParams` lands and is deployed. The vd PR is blocked on that;
no feature flag on this side.

Single vd PR, authored in this internal commit order for reviewability:

1. Frame + tabs. Adds `_tabs_menu.html.erb`, registers
   `:admin_secure_elections_menu`, deletes `_step_footer` and the
   `.vocdoni-step-nav` CSS. Every existing screen now shows the new tab
   strip; the wizard footer stops rendering. Screens keep their current
   bodies temporarily.
2. Details rewrite. Merges Calendar into Details as an accordion card, adds
   the Results accordion card, deletes `calendar/*`, drops autosave.
   Renames `start_immediately` → `manual_start` (with the semantic flip —
   delete the old `manual_start?` method first, then wire the new column /
   attribute / helpers per the Naming gotcha ordering). `start_time` →
   `start_at`.
3. Questions rewrite. New editor pack (upstream JS conventions), new
   partials, new template blueprint pattern, per-question `question_type`,
   drag handle. Deletes `_field_templates.html.erb`, deletes ballot-wide
   `question_type` on the form and its copy-down loop, moves
   `result_visibility` to Details form.
4. Census rewrite. Manifest selector + inline partial + preview + sticky
   save. Folds `voters` in.
5. Dashboard rewrite. Absorbs `show` + `monitor` + `setup` (the vd step
   currently labelled **"Publish"** in the nav) into one branching page.
   Renames the tab to **"Dashboard"**. Adds the completeness checklist
   partial that reuses `Election#*_complete?` predicates. Moves the
   `confirm_irreversible` checkbox + red "Publish on the blockchain"
   button into `dashboard/_publish`. Deletes the standalone `setup/show`
   view and the `Setup` step route; `SetupController` shrinks to the
   Publish endpoint or its guts fold into a Dashboard controller.
6. Elections index dropdown. Adopts upstream `resource_action_dropdown`.
   Deliberately does **not** expose Publish from the row dropdown —
   Publish goes through the Dashboard where the checkbox lives.
7. i18n cleanup. Removes strings the rewrite orphaned; renames the
   `start_immediately` keys.

## Testing plan

- System specs on each of the four tabs land (per-tab happy path plus one
  validation failure per tab).
- System spec for questions drag-reorder that asserts position persistence.
- System spec for the soft-delete question flow (Remove → Save →
  destroyed row).
- System spec for the Publish flow: `confirm_irreversible` checkbox
  disables/enables the submit button; submitting without ticking the
  checkbox fails validation server-side with the expected message.
- System spec for the born-paused / Start election flow. Runs
  unconditionally — the SaaS PR is a prerequisite of merge, so by the
  time this test lands the API accepts `InitialStatus: PAUSED`.
- System spec for the Dashboard checklist: each `*_complete?` predicate
  toggled off in turn keeps the Publish button disabled.
- No unit-level changes required beyond form/command coverage of the
  `start_immediately → manual_start` rename.
