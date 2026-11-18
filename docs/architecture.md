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

client.elections.create(payload)                        # POST /processes            -> { "processId" => … }
client.elections.get(process_id)                        # GET  /processes/{id}       (PUBLIC once published)
client.elections.publish(process_id)                    # POST /processes/{id}/publish -> { "jobId" => … }
client.elections.delete(process_id)                     # DELETE /processes/{id}     (drafts only)
client.elections.results(process_id)                    # GET  /processes/{id}/results (PUBLIC)
client.elections.attested_participant(process_id, voter_id)
                                                        # GET  /processes/{id}/participants?field=voterId
client.elections.attestations(process_id, page:)        # GET  /processes/{id}/attestations (PUBLIC, after the end)
client.elections.rotate_attestation_signer(process_id, signer)
                                                        # PUT  /processes/{id}/attestation-signer

client.jobs.wait_for(job_id, timeout: …)                # poll GET /jobs/{id} until terminal
```

### 2.1 Payload quirks — these bite

* **Language maps are mandatory.** `POST /processes` rejects a plain string for `title`,
  `description` or a choice `title` with `{"error":"invalid JSON request body","code":40004}`.
  The JS SDK normalizes plain strings client-side; **Ruby must do the same**.
  `ApiClient#localize` turns `"Hi"` into `{ "default" => "Hi" }` and passes a Decidim
  translated hash through as `{ "default" => <default-locale value>, "en" => …, "ca" => … }`.
* **The process census is inline and attested**:
  `census: { attested: { signer: "0x…", maxCensusSize: N }, twoFaFields: [] | ["email"] | ["phone"] }`.
  No member, group or org-level census is created; the standalone `POST /census` flow is
  not used.
* **Question type strings are lowercase**: `"singlechoice"`, `"multichoice"`. camelCase is
  rejected (code 40037). `multichoice` additionally requires
  `typeSetup: { maxChoices:, minChoices: }`. Upstream `decidim-elections` uses
  `single_option` / `multiple_option`; `PublishElectionJob` maps them.
* **`ballotProtocol` comes back `null`** for singlechoice questions. Never assume it is
  present.

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
  "census":      { "attested": { "signer": "0x…", "maxCensusSize": 12 }, "twoFaFields": ["email"] },
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
2. client.processes.authStep0(processId, attestation) → authToken
     the body is what Decidim's attestation endpoint returned: { attestation, signature, contact?, salt? }
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

The whole voter flow was walked end to end against staging, including a real vote whose
nullifier was returned.

## 4b. Database schema

Two tables, kept small on purpose: `decidim_vocdoni_processes`, one row per
Vocdoni-backed Decidim election, and `decidim_vocdoni_attestations`, one row per voterId
an election attested with its `issued_count` (see the migrations for the full column lists).

| column                  | type      | notes                                                                              |
|-------------------------|-----------|------------------------------------------------------------------------------------|
| `decidim_election_id`   | fk (unique) | one Vocdoni process per Decidim election; `on_delete: :cascade`                  |
| `vocdoni_process_id`    | string, unique-when-present | Mongo ObjectID minted by `POST /processes`                        |
| `vocdoni_upstream_id`   | string    | on-chain process id                                                                |
| `chain_id`              | string    | cached from the process read                                                       |
| `state`                 | string, default `"pending"` | `pending` / `publishing` / `published` / `failed`                |
| `last_error`            | string    | last non-transient failure message, surfaced on the dashboard                      |
| `attestation_signer_key`| text      | the election's EIP-712 signer key, encrypted; never leaves Decidim                  |
| `voter_id_secret`       | text      | HMAC key of the voterIds, encrypted; never leaves Decidim                          |
| `census_size`           | integer   | turnout denominator                                                                |
| `metadata`              | jsonb     | per-question upstream ids + statuses; `settings.twofa_fields`; `last_error` bag    |

`Process#published?` ⇒ `state == "published"`.
`Process#upstream_draft?` ⇒ `vocdoni_process_id.present? && !published?`.

Destroying the sidecar (via `dependent: :destroy` from the upstream election) attempts a
best-effort `DELETE /processes/{id}` when the row is an upstream draft, so a cancelled
Decidim election does not eat one of the org's draft slots. `404` and `40012`
("already on chain") are treated as success; anything else raises and rolls the destroy
back.

## 4c. Census — attested by Decidim

No roster leaves Decidim. When voting starts (at `start_at`, or when the admin clicks
Start), `PublishElectionJob` re-checks `election.census_ready?`, draws the election's
signer key and voterId secret once, and creates the process with an attested census:
the signer's address, `maxCensusSize` = ceil(eligible × 1.2) and the `twoFaFields` of the
Security tab. An attestation binds at most one contact, so the job refuses a census that
asks for more than one channel.

The booth then asks `POST <component>/elections/:id/vocdoni_attestation` for an EIP-712
attestation. Decidim answers only for a voter its census access let into the booth (the
election's upstream census, `internal_users` or `token_csv`, under Decidim's own rules),
so a participant who joins the census after the start can still vote while
`maxCensusSize` has room. The attestation carries:

- `voterId` = HMAC-SHA256(voter_id_secret, voter key ‖ processId): stable within the
  election, unlinkable across elections, meaningless to the SaaS.
- `contactHash` = keccak256(salt ‖ kind ‖ ":" ‖ contact) with 2FA, zero otherwise. The kind
  is the census's `twoFaFields[0]` (`email` or `phone`); the contact and salt travel only in
  the auth/0 and resend bodies.
- `expiresAt` = now + 10 minutes.

The contact must already be canonical, because the SaaS hashes the bytes it receives:

- email: trimmed, lowercased, NFC.
- phone: E.164, read from a CSV row's `phone` column or from a granted authorization's
  `phone`, `phone_number` or `mobile_phone_number` metadata (oldest first). NFKC folds
  full-width characters; spaces, `-`, `.`, `/`, brackets and a `(0)` trunk marker are dropped;
  a leading `00` becomes `+`; the result must be `+`, a non-zero digit, and 7–15 digits in
  all. A number without a country code is refused (Decidim has no country to assume), and
  the SaaS refuses at auth/0 any number libphonenumber does not call valid.

A voter without such a contact gets 422 `{ error: "no_contact", kind }` and the booth says
which contact is missing.

`decidim_vocdoni_attestations` counts what each voterId was issued (capped per voter), and
the Security tab compares that count with the records the SaaS publishes after the end.

Each publish step is **conditional and idempotent by design**, so a retry is safe:

- `POST /processes` is skipped once `vocdoni_process_id` is set.
- `POST /processes/{id}/publish` is skipped once the read-back reports the process
  is already `READY`/`ONGOING`/`ENDED`/`RESULTS`/`PAUSED`.

## 4c-bis. Two-factor voter flow

These override any assumption drawn from the SDK documentation.

1. `authStep0` takes the attestation body as is. With 2FA the SaaS checks `contact` and
   `salt` against `contactHash` and sends the code to `contact`.
2. **`check()` succeeds *before* the OTP.** A pending token still returns
   `belongsToProcess: true` and `canVote: true`. `check()` is therefore **not** an
   authentication gate — branch on `census.twoFaFields` from the public process
   read instead. An implementation that gates on `check()` skips 2FA entirely.
3. `authStep0` returns only `{ authToken }`; a pending token is indistinguishable
   from a verified one by shape.
4. Wrong OTP → `400 / 40001` *"challenge code do not match"*. The token survives,
   so the voter retries in place — never restart the flow or auto-resend.
5. `resend` takes `{ authToken, contact, salt }`, the same pair auth/0 received.

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
