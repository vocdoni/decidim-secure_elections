# UI/UX proposal — Census & Dashboard tabs

_Author: senior UI/UX pass, 2026-09-10._
_North star: `decidim.vocdoni.io` should be visually and interactionally indistinguishable from `try.decidim.org` (upstream `decidim-elections`), so that a future merge of `secure_elections` back into upstream is a code cleanup rather than a re-design._

---

## 1. What I compared and how

Live walkthrough on both deployments as `admin@example.org`, going through Main → Questions → Census → Dashboard for at least one editable and one on-chain election, plus the elections-list "Actions" dropdown. Screenshots at the repo root:

| file | what it shows |
|---|---|
| `screenshots/try-02-election-edit-main.png` | Upstream Main tab (accordion: Basic info / Calendar / Results availability) |
| `screenshots/try-04-census-internal-users.png` | Upstream Census: dynamic-participants manifest |
| `screenshots/try-05-census-token-csv.png` | Upstream Census: token-CSV manifest |
| `screenshots/try-06-dashboard-live.png` | Upstream Dashboard on a live election |
| `screenshots/try-10-elections-list-actions.png` | Upstream Elections list, Actions dropdown open |
| `screenshots/vd-01-elections-index.png` | Fork Elections list |
| `screenshots/vd-02-dashboard-pre-publish.png` | Fork Dashboard **before publishing** (checklist + 4 summary cards + publish action) |
| `screenshots/vd-03-census-fork.png` | Fork Census (3 numbered sections + preview + People + Add people) |
| `screenshots/vd-06-census-members.png` | Fork census members editor (`/census/members`) |
| `screenshots/vd-07-dashboard-onchain.png` | Fork Dashboard on a live election |

---

## 2. Executive summary

**Where we already match upstream (keep):**

- Four-tab strip labelled Main / Questions / Census / Dashboard, in the same order.
- Same `#census-manifest-selector` combobox at the top-right of the Census tab.
- Same per-question Results table (Answers / Votes / Percentage / Total).
- Same admin chrome: left process menu, breadcrumbs, "See process" button, sticky footer bar for primary actions.

**Where we diverge (and shouldn't):**

1. **Census tab is ~6× the surface area of upstream's**. Upstream is one combobox + one small form. We render a numbered 3-step accordion, a live security meter, a preview table, a People card with count badge, a two-accordion "Add people" section, and a background-autosave indicator — five to six cards where upstream has one.
2. **We have a pre-publish Dashboard; upstream doesn't**. Upstream's "Publish" is an item in the row-level Actions dropdown on the Elections index; the Dashboard tab is disabled until the election is live. We turn the same tab into a five-card readiness console (Checklist + About + Questions + Census + Publish).
3. **On-chain Dashboard has 6 cards where upstream has 2**. Upstream folds Status + Calendar into one "Election status" card and puts a single primary "End election" button. We split into Status / Turnout / Calendar / Results / Election controls (with 4 buttons) / Voting links.
4. **Copy is much heavier**. "This installation is connected to Vocdoni", "The last background operation failed: The Vocdoni memberbase rejected 6 of 2 voters …", "Blockchain election ID: 6be21…", etc. Upstream never surfaces infrastructure.

None of these divergences are wrong per se — Vocdoni-backed elections genuinely add irreversibility, an off-chain identity service and a live turnout figure that upstream doesn't have. The proposal below is about **carrying that extra weight without changing the shape of the page**.

---

## 3. Detailed gap analysis

### 3.1 Tabs strip

| | Upstream | Fork | Verdict |
|---|---|---|---|
| Labels | Main / Questions / Census / Dashboard | same | ✅ aligned |
| Icons | one per tab (document / chat / globe / grid) | same icons, same order | ✅ aligned (verified 2026-09-10, see `screenshots/tabs-try-upstream.png` vs `screenshots/tabs-vd-fork.png`) |
| Disabled state | Dashboard is `<span>` (no cursor) until election is set up | Dashboard is `<span>` too until saved | ✅ aligned |

### 3.2 Main tab

Upstream (`screenshots/try-02-election-edit-main.png`) is an **accordion of three sections** — Basic info / Calendar / Results availability — all expanded by default, with the sticky "Save and continue" at the bottom-right of the footer.

Fork's Main tab (didn't fully screenshot; see `_form.html.erb`) uses the same Decidim admin form scaffolding. It is likely already close enough. **No priority action here** — just make sure any new field we add follows the same "collapsible section" pattern rather than a new card.

### 3.3 Questions tab

Screenshot `e2e-dev-questions-fixed-2026-09-09.png` shows fork's Questions tab: a list of collapsible question cards + "Add question" + sticky "Save questions". Visually matches upstream — the recent rename of `title → body` (see `project_upstream_alignment_body`) closed most of that gap.

**One remaining divergence: the URL.**

| | upstream | fork |
|---|---|---|
| Questions tab URL | `/elections/:id/edit_questions` | `/elections/:id/questions/edit` |
| Path helper name | `edit_election_questions_path` (likely; upstream uses `member do get :edit_questions … end`) | `edit_election_questions_path` (via `resource :questions, only: [:edit, :update]`) |

Both engines end up with the same helper _name_, but the URL differs because the fork uses a singular nested resource while upstream uses a member action on the elections resource. There's no reason for the divergence — it's an accident of route definition. Fixing it is a two-line change in `admin_engine.rb`:

```ruby
# was
resource :questions, only: [:edit, :update], controller: "questions" do
  patch :autosave
end

# align with upstream
member do
  get   :edit_questions,   controller: "questions", action: :edit
  patch :update_questions, controller: "questions", action: :update
  patch :autosave_questions, controller: "questions", action: :autosave
end
```

Ten callers of the current helper today (`app/`, `lib/`, `spec/`) — most already use `edit_election_questions_path`, only the ones that reach the update endpoint (`election_questions_path` for the PATCH target) and the autosave endpoint need renaming. Ship as a standalone commit before Phase 3 so the URL alignment lands independently of the visual work.

Same audit for Census and Dashboard: **already aligned** (`/elections/:id/census`, `/elections/:id/dashboard`) — the singular `resource` we use happens to produce the same URL as upstream's member action in those two cases because Rails collapses `/census/show` to `/census` for the default show route.

### 3.4 Census tab — the biggest gap

Upstream (`screenshots/try-04-census-internal-users.png`) for the equivalent of our `internal_users` manifest is:

```
[combobox: Registered participants (dynamic)]

Additional required authorizations to vote (optional)
You can restrict participation …

 ☐ Code by postal letter (Multi-Step)
 ☐ Organization's census (Multi-Step)

[Save and continue]           (in sticky footer)
```

That's **it**. One form. One save button. Everything else — who's on the census, how many they are, uploading a CSV — is handled by the upstream **Participants** and **Verifications** admin sections, which the Elections module just borrows from.

Fork (`screenshots/vd-03-census-fork.png`) for the same manifest is:

```
[banner: The last background operation failed: … (long error) …]
                                              [combobox: Internal users]

1. Credentials
Required credentials
Choose what a voter has to type …
 ☑ First name    ☑ Last name    ☐ Member number    ☑ National ID    ☐ Date of birth
3 of 3 credentials selected
[green banner: Good security]

2. Two-factor verification
Verification method
A second factor sends the voter a one-time code …
 ○ No second factor          Voters are identified by their credentials alone.
 ○ Email verification        Voters receive a one-time code by email.
 ○ SMS verification          Voters receive a one-time code by text message.
 ○ Voter's choice            Voters choose whether to receive the code by email or by text message.

3. Summary
 ☐ Weight votes by voting power
   Give each person in the census a voting power …
Authentication guarantees
[    Weak    ][    Mid    ][   Strong   ]     (segmented, current: Mid)
Mid-level guarantees — three credentials, but no second factor. …

[preview table: Name/identifier | Added]
 Jonh Blah         08/09/2026
 Test Doe          08/09/2026
2 people in the census.

┌ People 2 people                                             ✎ Edit the list ┐
│ [red banner: 2 people are missing something they need …]                    │
│                                                                             │
│ [Empty the census]                                                          │
└─────────────────────────────────────────────────────────────────────────────┘

┌ Add people to the census ─────────────────────────────────────────────────── ┐
│ Add people one at a time, upload a spreadsheet, or bring in participants …  │
│  ▸ Import a file                                                             │
│  ▸ Add participants verified in Decidim                                      │
└──────────────────────────────────────────────────────────────────────────────┘

Changes save automatically.                        [Continue]  (sticky footer)
```

**Root cause of the bloat.** We chose to make the Census tab **also** be a place to (a) configure how voters are authenticated cryptographically, (b) manage the census roster and (c) surface a live security meter. Upstream only does (a). Roster is somewhere else entirely.

**What upstream does with the same three needs:**

| need | upstream location |
|---|---|
| Configure the census type | Census tab (combobox + one small form) |
| Manage the roster | Global **Participants** / **Verifications** admin (out of the election flow entirely) — or the census manifest ships its own edit page (e.g. `.../census/members`) reachable from a link, not embedded |
| Communicate "how strong is this configuration?" | not surfaced — implicit in the manifest chosen |

### 3.5 Dashboard tab (pre-publish)

**Upstream has none.** The Dashboard tab is disabled until the election is live. "Publish" is a link inside the Actions dropdown on the Elections list (`screenshots/try-10-elections-list-actions.png`), together with "Edit election", "Preview", "Move to trash".

Fork (`screenshots/vd-02-dashboard-pre-publish.png`) currently uses the same tab for **two different pages** based on `editable?`:

- **Editable** → a "readiness console" with five cards: Checklist / About this election / Questions / Census / Publish (with irreversibility checkbox + disabled button).
- **On-chain** → the live monitor (see 3.6).

The two are so different that reading them as one tab hurts the mental model.

### 3.6 Dashboard tab (on-chain)

Upstream (`screenshots/try-06-dashboard-live.png`):

```
┌ Election status ────────────────┐  ┌ Calendar ────────────────┐
│ Strategic Urban Plan 2035 — Live │  │ Start time: 14/10/2025 …│
│ Census: Unregistered … (fixed)   │  │ End time:   01/12/2027 …│
│ [Ongoing]  [Results avail. per Q]│  │                         │
└──────────────────────────────────┘  └─────────────────────────┘

Results
You need to enable voting and manually publish results …

  [Q1 heading] [Single option] [Voting in progress] [Publish results]
  [table: Answers | Votes | Percentage | Total]

  [Q2 heading] [Single option] [Voting in progress] [Publish results]
  [table …]

  …

There are currently 2 people eligible for voting (this might change on a dynamic census).

                                                     [End election]   (footer)
```

Two cards + a Results section + a single primary button. That's the whole live dashboard.

Fork (`screenshots/vd-07-dashboard-onchain.png`) is six blocks:

```
[banner: This election is on the blockchain and can no longer be edited.]

┌ Status ─────────────────┐  ┌ Turnout ────────────── ⟳ Refresh ┐
│ Status: [Voting open]    │  │ 100.0% (1 of 1)                  │
│ Start time: 09/09/2026 …│  │ Last refreshed 10/09/2026 09:55. │
│ End time:   15/09/2026 …│  │ This page reads locally stored …│
│ ▸ Technical details      │  │                                  │
└──────────────────────────┘  └──────────────────────────────────┘

┌ Calendar ──────────────────────────────────────────────────────┐
│ Start time [Manual start]                                      │
│ End time  15/09/2026 23:59                                     │
└────────────────────────────────────────────────────────────────┘

┌ Results ───────────────────────────────────────────────────────┐
│ [Q heading]                                        [Voting open]│
│ [table]                                                        │
│ Blockchain election ID: 6be21…000000                           │
└────────────────────────────────────────────────────────────────┘

┌ Election controls ─────────────────────────────────────────────┐
│ These controls change the state of every question …            │
│ [Resume voting]  [Pause voting]  [End election]  Cancel election│
└────────────────────────────────────────────────────────────────┘

⧉Voting links
Two links lead to this election …
The election page          https://…/processes/demo/f/1/elections/8   [Copy link] [Open]
Straight to the ballot     https://…/vocdoni/vote.html?v=…            [Copy link] [Open]
Only people on the census can vote. Everyone else can see the election …
```

**Divergences:**

1. Status and Calendar are split; upstream keeps them together.
2. Turnout is a first-class card; upstream never surfaces "turnout" at all as a number — it just says how many people are eligible at the bottom.
3. Four state-change buttons (Resume / Pause / End / Cancel) vs upstream's single "End election".
4. Blockchain election ID printed inside the Results card; upstream has no such thing.
5. Whole "Voting links" section with two URLs + explainer — upstream relies on Decidim's built-in Access links menuitem.

### 3.7 Elections list — Actions

Upstream (`screenshots/try-10-elections-list-actions.png`) has an Actions dropdown per row: **Edit election / Publish / Preview / Move to trash**. Fork's index dropdown on `screenshots/vd-01-elections-index.png` looks the same shape — actions per row, similar entries — that's good; we don't have Publish inside it, but adding it later is trivial.

---

## 4. Proposal

Three phases, each shippable on its own. Every phase moves us closer to upstream and cheaper to merge.

### Phase 1 — Visual pass (1–2 days)

Cosmetic, no logic changes. Kill the low-hanging divergences so the two sites look like the same product.

- **On-chain Dashboard: reshape into two side-by-side cards matching upstream** — "Election status" (left, with the status badge, an optional census-type subtitle and turnout inline) and "Calendar" (right, dates + manual-start button when applicable). Turnout stops being its own card and becomes a small `label` chip next to the status badge ("Voting open · 100 % turnout"); the Refresh control moves into the top-right of the Election status card since that's where the polled fields live. The Vocdoni-specific fields (upstream status, process id, chain id) fold behind a "Technical details" `<details>` disclosure inside the same card, same as today.
- **On-chain Dashboard: rename "Election controls" card into a single primary action + a small "More actions" ⋯ menu.** Primary is "End election" matching upstream. Under ⋯: Pause / Resume (if the protocol actually needs both), Cancel election (red destructive item).
- **Pre-publish Dashboard: drop the About / Questions / Census summary cards.** They just duplicate what the sibling tabs show. Keep the Checklist card (the fix-it links are genuinely useful for our irreversibility story) and the Publish action card. Two cards, not five.
- **Voting links section: collapse into an "Access links" disclosure at the bottom.** Explanatory prose stays, but folded. Upstream doesn't render this at all — for us it's genuinely useful because the /vocdoni/vote.html link isn't reachable through the standard Decidim access-link machinery.
- **Trim copy on `_status.html.erb`.** "Blockchain election ID: 6be21…" already lives inside the Technical details `<details>`; make sure it's not printed twice.

### Phase 2 — Flatten the Census tab (3–5 days)

- **Collapse the 3 numbered sections into one flat form** — one heading ("Voter authentication"), one fieldset for credentials, one fieldset for two-factor, one weighted-votes checkbox at the bottom. Drop the "1." / "2." / "3." numbering; upstream doesn't step-number its census form.
- **Move the security meter out of the tab body** into a small stat next to the manifest combobox: `Security: [Mid]` as a chip, tap-to-explain via tooltip. Or drop entirely — the manifest chosen already implies it.
- **Move People + Add people out of the Census tab.** The People card and the "Add people to the census" card become **one link** in a small "Manage people (N)" affordance at the bottom of the Census form, jumping to `/census/members` (which already exists — `screenshots/vd-06-census-members.png`). Import a file / Add participants from Decidim become sections **inside** `/census/members`, not in the manifest configuration page. Rationale: upstream's Census tab configures the census; roster management is a different job on a different page.
- **Drop the preview table.** If someone wants to see who's on the roster, "Manage people (N)" gets them to the full editor in one click. Upstream doesn't render a preview.
- **Retire the autosave indicator, replace with "Save and continue" in the sticky footer** — upstream's pattern is explicit save; no other tab in the fork autosaves either, so this is also an internal-consistency win.

At the end of Phase 2 the Census tab reads as: combobox top-right, single-column form below, sticky "Save and continue" in the footer, plus a "Manage people (2)" link. That is one screen and matches upstream's shape.

### Phase 3 — Publish flow (3–5 days)

- **Move the Publish action to the Elections list Actions dropdown**, matching upstream. Row-level "Publish" opens a confirmation page that carries the irreversibility checkbox + the completeness checklist — that whole page is what today's pre-publish Dashboard shows, but at `.../elections/N/publish` and only when the admin explicitly asks to publish.
- **Disable the Dashboard tab pre-publish** — `<span>` not `<a>`, matching upstream. The tab lights up when the election is on-chain.
- **After publishing**, redirect to the on-chain Dashboard (the redesigned one from Phase 1), same as upstream redirects after publish.
- **Move the checklist logic to the Publish confirmation page** — `election.details_complete? / questions_complete? / census_complete? / calendar_complete? / module_configured?`. If any check fails, the Publish button on the confirmation page is disabled, with fix-it links back into the four tabs (same predicates, same links, just moved). Everything the fork does today about "the admin should know why Publish is disabled" survives — it just runs on a screen that only opens when the admin has already committed to publishing.

### Phase 4 — Upstream merge (out of scope, but keep in view)

With Phases 1–3 shipped, the visual and interactional deltas between `secure_elections` and `decidim-elections` collapse to:

- one extra census manifest ("Secure via Vocdoni") — same combobox slot, one form, one save button;
- one extra `results_availability` mode ("Blockchain-backed") — one more radio in the Results availability accordion on Main;
- the irreversibility warning on the Publish confirmation page — one extra paragraph plus a checkbox.

At that point folding `secure_elections` into `decidim-elections` upstream is code alignment (SetupForm ↔ upstream's form, DashboardController ↔ upstream's controller, per-question status handling ↔ upstream's per-question publish) rather than a re-negotiation of the UX contract. The `title → body` rename we shipped 2026-09-09 was the first move on this path; each of Phases 1–3 removes one more diff.

---

## 5. Prioritised quick wins (this week, in order)

1. Reshape on-chain Dashboard into two upstream-matching cards (Election status + Calendar) and drop the standalone Turnout card. **Half day**, no data model change.
2. Reduce Election controls to primary "End election" + "More actions" menu. **Half day**.
3. Kill the four About/Questions/Census summary cards on the pre-publish Dashboard, keep the Checklist + Publish card only. **Half day**.
4. Fold Census tab's three numbered sections into one flat form (renderer change; the underlying form fields don't move). **1 day**.
5. Move People + Add people out of the Census tab into `/census/members`, link with "Manage people (N)". **1–2 days**, includes moving the `import` and `verifications` partials into the members view.
6. Align the Questions URL with upstream (`/edit_questions` instead of `/questions/edit` — see §3.3). **1 hour**, routes + ~10 helper renames + spec fixes. Ship as its own commit.

Everything past that (publish-as-list-action, disabling Dashboard pre-publish, confirmation-page checklist) is Phase 3 and needs a small controller and routing refactor — schedule it after the Phase 2 census work has settled.

---

## 6. Non-goals for this pass

- No visual redesign of Main or Questions tabs — they're already close enough to upstream. The rename of Question/Answer `title → body` (2026-09-09) took Questions the rest of the way.
- No change to the voter-facing pages. This proposal is admin-side only.
- No change to the Vocdoni SaaS wire protocol. All the copy trimming, card merging and tab reshuffling above is UI code — the JSON payloads to `saas-api-dev.vocdoni.net` and the /vocdoni/vote.html bundle stay untouched.
