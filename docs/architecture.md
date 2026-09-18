# Architecture

The reference the code is written against. Source comments cite it by section — you
will see `ARCHITECTURE §3` and the like throughout the module.

Two things are in here:

* **the invariants this module holds itself to** (§0, §5), each enforced by a lint rule,
  a spec, or both;
* **how the Vocdoni SaaS API behaves** (§1–§4), as observed against a running deployment.
  Where this disagrees with the Vocdoni SDK documentation, what is written here is what
  the API does.

## 0. Invariants

Each of these is here because getting it wrong costs somebody a ballot or their ballot
secrecy, not because it is tidy.

1. **No Node.js on the server.** Ruby talks to the SaaS REST API over HTTPS through
   `Decidim::Elections::Vocdoni::ApiClient`. Never shell out.
2. **No secret ever reaches the browser.** The integrator API key is server-side only.
   The voter path uses only public/CSP-token routes.
3. **No secret in process-global state.** Never assign to `ENV` at runtime; pass config
   explicitly through `Decidim::Elections::Vocdoni`.
4. **No `console.log` in the voter path.** Ballots and keys must never hit the console.
   ESLint enforces `no-console` under `app/packs/src/decidim/elections/vocdoni/voter/`.
5. **No SaaS call inside a web request.** All writes and all slow reads go through
   ActiveJob (`PublishElectionJob`, `SyncProcessJob`). The admin UI reads the sidecar's
   local columns; nothing on the request path calls the SaaS.
6. **Fail loudly on misconfiguration.** `Decidim::Elections::Vocdoni.validate_configuration!`
   raises rather than defaulting to a test chain.

## 1. Vocdoni model → Decidim model

This gem does **not** own its own election, question or answer models. It attaches a
sidecar to the upstream `decidim-elections` models so that upstream's schema stays
untouched:

| Upstream (`decidim-elections`)  | This gem                                              | Vocdoni                                  |
|---------------------------------|-------------------------------------------------------|------------------------------------------|
| `Decidim::Elections::Election`  | `Decidim::Elections::Vocdoni::Process` (sidecar row)  | process (Mongo ObjectID, 24 hex)         |
| `Decidim::Elections::Question`  | per-question metadata under `Process#metadata`        | question — its own Vochain election      |
| `Decidim::Elections::Answer`    | (no sidecar; upstream owns it)                        | choice `{title, value}`                  |

One process has many questions. **Each question is a separate Vochain election.** Voting
casts one transaction per question. `sign()` takes the *question's* `upstreamId` as
`electionId` — never the process id. This is the single easiest thing to get wrong.

Opt-in to Vocdoni is materialised by the presence of the `Vocdoni::Process` sidecar,
created from the Security tab. Its absence means the election runs as a plain Decidim
election.

## 2. Ruby `ApiClient` contract

`Decidim::Elections::Vocdoni::ApiClient.new` reads config from
`Decidim::Elections::Vocdoni`. Sub-clients mirror the JS SDK: `#elections`,
`#organizations`, `#jobs`.

Methods actually called from this module (snake_case Ruby, hash returns with string keys):

```ruby
client.organizations.create_managed(name:, type:, ...)  # POST /integrator/organizations -> { "address" => "0x…" }
client.organizations.add_members(org_address, members)  # POST /organizations/{addr}/members
client.organizations.members(org_address, page:)        # GET  /organizations/{addr}/members (paginated)
client.organizations.create_group(org_address, title:, description:, member_ids:)
                                                        # POST /organizations/{addr}/groups
client.organizations.groups(org_address)                # GET  /organizations/{addr}/groups

client.elections.create(payload)                        # POST /processes            -> { "processId" => … }
client.elections.get(process_id)                        # GET  /processes/{id}       (PUBLIC once published)
client.elections.validate_census(org_address, census)   # POST /processes/census/validation
client.elections.publish(process_id)                    # POST /processes/{id}/publish -> { "jobId" => … }
client.elections.delete(process_id)                     # DELETE /processes/{id}     (drafts only)
client.elections.results(process_id)                    # GET  /processes/{id}/results (PUBLIC)

client.jobs.wait_for(job_id, timeout: …)                # poll GET /jobs/{id} until terminal
```

### 2.1 Payload quirks — these bite

* **Language maps are mandatory.** `POST /processes` rejects a plain string for `title`,
  `description` or a choice `title` with `{"error":"invalid JSON request body","code":40004}`.
  The JS SDK normalizes plain strings client-side; **Ruby must do the same**.
  `ApiClient#localize` turns `"Hi"` into `{ "default" => "Hi" }` and passes a Decidim
  translated hash through as `{ "default" => <default-locale value>, "en" => …, "ca" => … }`.
* **The process census is inline**, not a reference:
  `census: { authFields: ["memberNumber"], groupId: "<org group id>", weighted: false }`.
  The standalone `POST /census` flow is a *different*, org-level concept — this gem does
  not use it.
* **Question type strings are lowercase**: `"singlechoice"`, `"multichoice"`. camelCase is
  rejected (code 40037). `multichoice` additionally requires
  `typeSetup: { maxChoices:, minChoices: }`. Upstream `decidim-elections` uses
  `single_option` / `multiple_option`; `PublishElectionJob` maps them.
* **`ballotProtocol` comes back `null`** for singlechoice questions. Never assume it is
  present.
* **`weight` on a member must be a JSON string, not a number.** Passing `{"weight": 1}`
  fails with `40004 "missing members"` — the error names the wrong field. `"1"` works.

### 2.2 Async jobs

`publish` and `bulk_set_question_status` return `{"jobId": …}`. Poll `GET /jobs/{id}`
until `status` is `completed` or `failed`.

⚠️ The job body contains a **nested `result.status`** (e.g. `"READY"`) that is *not* the
job status. Parse `body["status"]` at the top level only — a naive regex/`sed` grabs the
wrong one.

A successful publish looks like:
`{"jobId":"…","type":"publish_voting_process","status":"completed","result":{"status":"READY"}}`

### 2.3 A complete `POST /processes` body

```json
{
  "orgAddress": "0x0000000000000000000000000000000000000001",
  "title":       { "default": "…" },
  "description": { "default": "…" },
  "endDate":     "2026-07-29T14:51:08Z",
  "census":      { "authFields": ["memberNumber"], "groupId": "000000000000000000000001", "weighted": false },
  "questions":   [{
    "title":   { "default": "…" },
    "type":    "singlechoice",
    "choices": [{ "title": { "default": "Yes" }, "value": 0 },
                { "title": { "default": "No" },  "value": 1 }]
  }]
}
```

`startDate` may be omitted — the process then starts as soon as it is published.

## 3. Voter flow (browser only)

The sequence implemented in `app/packs/src/decidim/elections/vocdoni/voter/`:

```
1. client.elections.get(processId)              → chainId  (PUBLIC; never use client.info())
2. client.processes.authStep0(processId, {...}) → authToken
     census.twoFaFields null/empty ⇒ auth-only: token is already verified, SKIP authStep1
     otherwise                     ⇒ authStep1(processId, { authToken, authData: [otp] })
3. client.processes.check(processId, { authToken })
     → { belongsToProcess, weight, questions: [{ questionId, upstreamId, canVote, hasVoted }] }
       Ineligible is belongsToProcess=false with HTTP 200 — not an error. Handle it as UI state.
4. per question: client.processes.getQuestion(processId, questionId)  (PUBLIC)
5. const signer = new EphemeralSigner()          // fresh per vote, never reused
   client.processes.sign(processId, { authToken, electionId: upstreamId, payload: signer.address })
     → { signature, weight }        // a question's signing slot is consumed on success
6. votingClient.vote({ processId: upstreamId, chainId, choices, signer,
                       cspSignature, cspWeight })            → jobId
7. client.jobs.waitFor(jobId)                    → job.result.voteID   // the nullifier
```

Ballot encoding — `ballotProtocol` may be absent, so branch on question type:
* `singlechoice` → `[selectedIndex]`
* `multichoice`  → one element per choice, `1` selected / `0` not

For `secretUntilTheEnd` questions, `question.encryptionKeys` is **absent until the keykeepers
publish**. Poll until present and only then build the ballot — never cast cleartext as a
fallback.

## 4. Values read from a deployment

| Key | Value |
|---|---|
| API base | one of `saas-api.vocdoni.net`, `saas-api-stg.vocdoni.net`, `saas-api-dev.vocdoni.net` |
| Explorer | derived: `explorer.vote`, `stg.explorer.vote`, `dev.explorer.vote` |
| `orgAddress` | `0x…` — one per integrator, from `organizations.create_managed` |
| `chainId` | e.g. `vocdoni/LTS/1.2` (read from the process, not `/info`) |
| Auto member group | every organization gets an "All members" group on creation |

The whole voter flow was walked end to end against staging, including a real vote whose
nullifier was returned.

## 4b. Database schema

Exactly one table, kept small on purpose: `decidim_vocdoni_processes`, one row per
Vocdoni-backed Decidim election (see the migration for the full column list and reasoning).

| column                  | type      | notes                                                                              |
|-------------------------|-----------|------------------------------------------------------------------------------------|
| `decidim_election_id`   | fk (unique) | one Vocdoni process per Decidim election; `on_delete: :cascade`                  |
| `vocdoni_process_id`    | string, unique-when-present | Mongo ObjectID minted by `POST /processes`                        |
| `vocdoni_upstream_id`   | string    | on-chain process id                                                                |
| `chain_id`              | string    | cached from the process read                                                       |
| `state`                 | string, default `"pending"` | `pending` / `publishing` / `published` / `failed`                |
| `last_error`            | string    | last non-transient failure message, surfaced on the dashboard                      |
| `census_group_id`       | string    | Vocdoni org member-group id built for this election                                |
| `census_size`           | integer   | turnout denominator                                                                |
| `metadata`              | jsonb     | per-question upstream ids + statuses; `settings.twofa_fields`; `last_error` bag    |

`Process#published?` ⇒ `state == "published"`.
`Process#upstream_draft?` ⇒ `vocdoni_process_id.present? && !published?`.

Destroying the sidecar (via `dependent: :destroy` from the upstream election) attempts a
best-effort `DELETE /processes/{id}` when the row is an upstream draft, so a cancelled
Decidim election does not eat one of the org's draft slots. `404` and `40012`
("already on chain") are treated as success; anything else raises and rolls the destroy
back.

## 4c. Census creation — Decidim owns it

The admin never sees or types a Vocdoni id. `PublishElectionJob` collects voters from
the Decidim side and builds the whole upstream chain itself. Endpoints, in order:

```
1. POST /organizations/{orgAddress}/members
     { members: [{ memberNumber, name, email, ... }] }
     → { added, errors[], jobId? }   ← poll jobId when present
2. GET  /organizations/{orgAddress}/members?page=N
     paginated read-back to map each Decidim user to the upstream `memberId` — the
     import does not return them when members already exist. Capped at 200 pages.
3. POST /organizations/{orgAddress}/groups
     { title, description?, memberIds: [...] }        → { id }
4. POST /processes/census/validation
     { orgAddress, census: { authFields, twoFaFields, groupId, weighted } }
     → 200 on success; 400 with `data.{duplicates, missingData, notFound}` on failure
5. POST /processes ... census: { authFields, twoFaFields, groupId, weighted }
6. POST /processes/{id}/publish
```

Step 4 is what catches "you asked to authenticate on `email` but 12 members have none"
*before* anything is written on chain. Its 400 body carries actionable member ids that
`PublishElectionJob` records on the sidecar so the admin dashboard can name them.

Each step is **conditional and idempotent by design**, so a retry after a mid-way
failure is safe rather than duplicative:

- `POST /members` is skipped when there is nothing fresh to push; `add_members` is
  deduped against the upstream index by `memberNumber` because the endpoint is not
  upsert-by-`memberNumber`.
- `POST /groups` is skipped once `census_group_id` is set.
- `POST /processes` is skipped once `vocdoni_process_id` is set.
- `POST /processes/{id}/publish` is skipped once the read-back reports the process
  is already `READY`/`ONGOING`/`ENDED`/`RESULTS`/`PAUSED`.

The whole census phase is skipped once `vocdoni_process_id` is set: a published process
carries a frozen census, so there is nothing left to build.

### Member field roles

| field           | 2FA-capable | usable as credential |
|-----------------|-------------|----------------------|
| `memberNumber`  |             | ✓                    |
| `nationalId`    |             | ✓                    |
| `name`          |             | ✓                    |
| `surname`       |             | ✓                    |
| `birthDate`     |             | ✓                    |
| `email`         | ✓           |                      |
| `phone`         | ✓           |                      |
| `weight`        |             | never                |

`authFields` (credentials) are chosen from the ✓ column, **max 3**.
`twoFaFields` derive from a single choice:
`email → ["email"]`, `sms → ["phone"]`, `voter_choice → ["email","phone"]`.

A census with no `authFields` and no `twoFaFields` identifies nobody and must stay
refused.

## 4c-bis. Two-factor voter flow

Observed against a 2FA election (`twoFaFields: ["email"]`). These override any
assumption drawn from the SDK documentation.

1. **`authStep0` needs the contact value as well as the credentials.** Credentials
   alone fail with `400 / 40005` — *"no contact information provided (email or
   phone)"*. So the voting page's auth form must also collect the channel value:
   `authStep0(pid, { memberNumber: "2001", email: "carol@example.org" })`.
   `["email"]` → ask email; `["phone"]` → ask phone; `["email","phone"]` → let the
   voter choose a channel, then ask for that one value.
2. **`check()` succeeds *before* the OTP.** A pending token still returns
   `belongsToProcess: true` and `canVote: true`. `check()` is therefore **not** an
   authentication gate — branch on `census.twoFaFields` from the public process
   read instead. An implementation that gates on `check()` skips 2FA entirely.
3. `authStep0` returns only `{ authToken }`; a pending token is indistinguishable
   from a verified one by shape.
4. Wrong OTP → `400 / 40001` *"challenge code do not match"*. The token survives,
   so the voter retries in place — never restart the flow or auto-resend.
5. `resend` requires the contact value: `resend(pid, { authToken, email })`. With
   only the token it fails `40001` *"invalid user email"*.
6. A right-credential / wrong-contact pair is rejected at step 0 with `40029`
   *"census participant not found"* — it does not disclose census membership, so
   show a generic "we could not identify you" rather than echoing the API.

## 4d. Decisions taken, and why

1. **Sidecar, not fork or table-alteration.** Upstream owns `Election`, `Question`,
   `Answer` and their schema; this gem owns one extra table keyed to the upstream
   election. Upstream migrations touch upstream's tables, this migration touches ours,
   and both can advance independently.
2. **Question type is per question, not per process.** Each question is its own
   Vochain election and the voting page encodes a ballot per question, so the type
   belongs to the question.
3. **A vote is never linked to a voter.** The census authenticates against the CSP,
   which returns a blind signature; the ballot is then cast with an ephemeral key
   generated in the browser and discarded. Decidim stores the census, never a vote.
4. **The tally is read from the chain, never from Decidim.** The sidecar caches
   `census_size` and per-question chain-side status; result numbers come from the SaaS
   directly. Anything that disagrees with the chain is a stale cache, not a different
   result.

## 5. Decidim conventions that apply

* Commands validate a form then `broadcast(:ok)` / `broadcast(:invalid)`.
* Forms carry validation; models stay thin.
* English is the source language; other locales come from translators.
* JS selectors use `id` with a `js-` prefix or `data-` attributes — never CSS classes.
* All UI must satisfy WCAG 2.1 AA and Decidim's own accessibility guide.
* Prefer vanilla JS. This module deliberately does **not** use the SDK's React layer.
