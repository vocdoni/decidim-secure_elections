Status: abandoned 2026-11-09 — superseded by the integrator-attested census (vocdoni/saas-backend#858, vocdoni/decidim-secure_elections#69). Code: branch `abandoned/decidim-as-csp` in the repos above.

# Decidim as the CSP for Vocdoni elections: design

Status: draft. Scope: `decidim-secure_elections` gem, the Decidim fork (`demo/integrated-booth`), saas-backend.

## 1. Goal

Decidim signs each eligible voter's ephemeral voting address after its own census check, which stays dynamic as in vanilla Decidim.
- The census is not pushed to the SaaS memberbase, so voter personal data stays in Decidim.
- Publishing an election to the SaaS means "per-question CSP public key + maxCensusSize".
- The SaaS still creates the process on chain, holds the org account, relays votes and serves results.

## 2. Decisions

| # | Decision |
|---|---|
| D1 | A secret root keyring in Decidim (`VOCDONI_CSP_ROOTS`). Each on-chain election (one per Decidim question) gets a key derived from the root recorded on its process, with the `electionkey` design of saas-backend #796. Per question only the public 12-byte seed is stored. |
| D2 | Plain ECDSA for the December pilot; Decidim can link voter to address (§8). Blind V3 later (§9). |
| D3 | An "external CSP" census mode in saas-backend: the integrator stores per-question roots on the draft and declares maxCensusSize; the SaaS skips memberbase/OTP, never signs, and prices by the declared size. |
| D4 | **Origin `OFF_CHAIN_CA_V2`, proof type `ECDSA` (unsalted).** `OFF_CHAIN_CA_V3_ECDSA` once sequencer #13 is live: same proof bytes, only the origin enum changes. |
| D5 | One signed address per (voter digest, question), pinned forever. The digest is keyed by a dedicated, never-rotated `VOCDONI_CSP_PIN_SECRET`. Re-signing the same address is idempotent; a different address is refused. |
| D6 | Roots are immutable for the life of an election (`dynamicCensus:false`); root rotation applies only to elections published afterwards. |

## 3. Chain and proof format (evidence)

**What the chains accept**
- **DEV/36** runs vocdoni-node (it has anonymous elections); 7 of its 119 elections are `OFF_CHAIN_CA_V2`, all with 33-byte roots.
- **LTS/1.3** (vocdoni-node-priv, `election_tx.go:60`, `proof.go:61`) and sequencer `main` 3ac4fea8, which LTS runs in December (`election_tx.go:59`, `proof.go:54-56`), both accept `OFF_CHAIN_CA`/`_V2` for new processes; the sequencer logs `OFF_CHAIN_CA` as deprecated. **Use V2.**
- **Sequencer PR #13** (draft, undeployed, like saas #796) retires both legacy origins (`election_tx.go:61-64` there) and adds `V3_ECDSA`.

**Verification** (sequencer `cspproof.go:42-131`, identical in vocdoni-node-priv and vocdoni-node): `bundle.Address` must equal the vote signer and `bundle.ProcessId` the envelope's (49-55). For `ECDSA`, the chain recovers the signer of `proto.Marshal(bundle)` under the EIP-191 hash, compresses it and compares it with `process.CensusRoot` (62-93). Weight = `voteWeight`, or 1 if absent (128-131). V3_ECDSA (`cspv3.go:69-79` on PR #13) also requires a 65-byte signature and a non-zero weight. The root is per process, so a per-election key works on V2 now.

**Other chain rules**
- Votes are capped at `maxCensusSize` (`vote_tx.go:187`). nullifier = `keccak256(address ‖ processId)` (`state/utils.go:15`).
- CA origins have `AllowCensusUpdate` and `NeedsURI` (`state/censusorigins.go:24-31`), but a root or URI change also needs `Mode.DynamicCensus` (`state/process.go:386-397`). saas always publishes `dynamicCensus:false` (`account/ballot.go:340`), so an election's root is immutable and `SET_PROCESS_CENSUS` can only raise `maxCensusSize`: a size-only tx skips the DynamicCensus gate, and the tx check accepts increases only, priced by `txCostIncreaseCensusSize` (sequencer `election_tx.go:221-244`; vocdoni-node-priv `state/process.go:403-414`, `election_tx.go:225-230`).

### Exact bytes

```
processId  = 32-byte on-chain election id of the question (SaaS question.upstreamId)
address    = 20-byte ephemeral voter address
bundle     = 0a 20 ‖ processId ‖ 12 14 ‖ address ‖ 1a 01 01          (59 bytes, CAbundle fields 1,2,3)
digest     = keccak256("\x19Ethereum Signed Message:\n59" ‖ bundle)   (length always computed, never hardcoded)
signature  = r(32) ‖ s(32) ‖ v(1), v ∈ {0,1}, low-s, RFC 6979 nonce   (65 bytes)
proof      = ProofCA{type: ECDSA, bundle, signature}
```

- Prefix bytes (28): `19 45 74 68 65 72 65 75 6d 20 53 69 67 6e 65 64 20 4d 65 73 73 61 67 65 3a 0a 35 39`. Re-derived from the #796 vector "ecdsa weight 42" (59-byte bundle): digest `7d10a299…0d25e17c`; its signature `4cfe08ba…95b201` verifies under root `02886e8c…46bd` with `\n59` and fails with `\n58` (OpenSSL 3.5.5).
- `voteWeight` is always `0x01`. V3 rejects an empty weight, and the JS rebuilds the bundle from `cspWeight` (`@vocdoni/api-voting@1.2.1` `src/vote-transaction.ts:68-74`, `:119`), so the client passes `"01"`.
- Each question is its own on-chain election with its own key and bundle; `processId` is the binding.

## 4. Key derivation

Port of saas-backend #796 `csp/signers/electionkey/electionkey.go:9-12,97-149`:

```
hashToScalar(tag, data) = first keccak256(tag ‖ u32be(i) ‖ data), i=0..255, with 0 < h < n
dE(seed) = hashToScalar("vocdoni/csp/v3/election-ecdsa", root(32) ‖ seed(12))
censusRoot = compress(dE·G)   (33 bytes)
```

- **root**: a 32-byte secp256k1 scalar (`NewRoot` check), from `openssl rand -hex 32`. Each environment (dev, prod) has its own root. Boot logs `csp_root_id` (never the key); prod refuses to start if its `csp_root_id` is on a denylist of non-prod ids.
- **seed**: the 12-byte Mongo ObjectID of the SaaS `VotingProcessQuestion` (#796 `csp/election.go:74`), stored as `vocdoni_question_id` under a unique index so no two questions share a key. "Seed" means only this.
- Blind tags (`election-blind`, `weight-key`) are reserved for §9.
- **Ruby needs no gem.** On a dev server (Ruby 3.4.7, OpenSSL 3.5.5) a ~40-line stdlib port reproduced `testdata/csp-v3-vectors.json` byte for byte: `electionEcdsaKey` for both seeds and the "ecdsa weight 42" signature (RFC 6979, low-s, as go-ethereum `Sign`). The prod image needs OpenSSL ≥ 3.2; boot fails fast if `OpenSSL::Digest.new("KECCAK-256")` raises.

Core (reference, verified):

```ruby
N = OpenSSL::BN.new("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141", 16).to_i
G = OpenSSL::PKey::EC::Group.new("secp256k1")
def keccak(b) = OpenSSL::Digest.new("KECCAK-256").digest(b)
def i2b(i) = [i.to_s(16).rjust(64, "0")].pack("H*")
def b2i(b) = b.unpack1("H*").to_i(16)
def hash_to_scalar(tag, data)
  256.times { |i| h = b2i(keccak(tag.b + [i].pack("N") + data)); return h if h.between?(1, N - 1) }
  raise "no scalar"
end
def rfc6979_k(d, h) # HMAC-SHA256, h = 32-byte digest, as libsecp256k1
  x = i2b(d); v = "\x01".b * 32; k = "\x00".b * 32; hm = ->(kk, m) { OpenSSL::HMAC.digest("SHA256", kk, m) }
  k = hm.(k, v + "\x00".b + x + h); v = hm.(k, v); k = hm.(k, v + "\x01".b + x + h); v = hm.(k, v)
  loop { v = hm.(k, v); t = b2i(v); return t if t.between?(1, N - 1); k = hm.(k, v + "\x00".b); v = hm.(k, v) }
end
def sign_eth(d, msg)
  z = keccak("\x19Ethereum Signed Message:\n\#{msg.bytesize}".b + msg); k = rfc6979_k(d, z)
  rp = G.generator.mul(OpenSSL::BN.new(k)).to_octet_string(:uncompressed)
  r = b2i(rp[1, 32]) % N; v = rp[64].ord & 1; s = (k.pow(N - 2, N) * (b2i(z) + r * d)) % N
  (s = N - s; v ^= 1) if s > N / 2
  i2b(r) + i2b(s) + v.chr
end
```

**Specs**: the vectors JSON copied byte-identical into `spec/fixtures/` (keys for both seeds, the ECDSA bundle and signature); the signature must not recover to the other seed's root; sign-then-recover yields `censusRoot`; the Ruby bundle for weight `01` equals `encodeCaBundle` of `@vocdoni/api-voting@1.2.1` (jest, shared fixture); and a Go-generated S1b fixture, one `OFF_CHAIN_CA_V2` ECDSA proof with weight `01` verified by `ProofVerifierCSP{V2:true}`, reproduced byte for byte.

## 5. Decidim components

1. **`Vocdoni::CspKeyring`** (lib)
   - Roots come from credentials or ENV `VOCDONI_CSP_ROOTS=id1:hex,id2:hex`, never the DB or `secret_key_base`. `csp_root_id` = first 8 bytes of `keccak(pub(root))`.
   - A new process records the newest root's id; signing always uses that recorded root. If it is missing, sign refuses with `csp_root_missing` (500, alert), never falling back.
   - An open election's key cannot be rotated (§3). If it is compromised, end the election and republish it.
   - `VOCDONI_CSP_PIN_SECRET`: 32 bytes, separate from the keyring, never rotated. Each process records `pin_secret_id` (first 8 bytes of `keccak(secret)`); sign refuses with `pin_secret_mismatch` if it differs.
2. **Table `decidim_elections_vocdoni_csp_pins`**: `process_id`, `decidim_question_id`, `csp_root_id`, `seed`, `election_id`, `voter_digest`, `address`, `nullifier`, `vote_confirmed_at`, timestamps. No signature: RFC 6979 re-derives it.
   - `voter_digest` = HMAC-SHA256(pin secret, voter key). The voter key is election-scoped: `"row:" ‖ election_id ‖ ":" ‖ Voter.id` for `token_csv`; for `internal_users`, `"user:" ‖ election_id ‖ ":" ‖ voter_uid` (whoever the upstream census admits, as a memberbase entry in vocdoni-app).
   - Unique indexes `(decidim_question_id, voter_digest)`, whatever root is active, and `(decidim_question_id, address)`.
   - **Invariant: no code path may produce a second pin for the same voter and question.** Rotation and admin actions never delete or replace a pin; the purge (§8) clears `address` but keeps the row. A spec asserts that adding a keyring entry changes neither `voter_digest` nor the "different address → 409" behaviour of an open election.
3. **`VoterCspController`** (frontend engine). Includes the fork's `UsesCensusAccess` (`uses_census_access.rb:19-29`; `voter_uid` comes from `election.census`, so the census stays dynamic) and requires CSRF. `token_csv` voters need no `current_user`: the census session (`session_attributes`) identifies them; ending it ends access, the pin stays.
   - `GET …/csp/status` → per question `{questionId, votingEnabled, canVote, pinnedAddress, nullifier, hasVoted}`.
   - `POST …/csp/sign {questionId, address}` → `{signature, weight: "01", proofType: "ECDSA"}`; the election id is derived server-side.
   - Sign algorithm:
     1. Permission `:create, :vote`; election ongoing; process `verified` (§5.6); question in the metadata with chain status READY; and when `election.per_question?`, `question.voting_enabled?` (`question.rb:53-55`). Otherwise 409 `question_closed`.
     2. Require `voter_uid.present?`.
     3. Pin with the same address: re-sign, no cap check. Different address: **409 `address_pinned`**.
     4. No pin: lock the process row (`SELECT … FOR UPDATE`); if the current roster count exceeds `maxCensusSize` (as last read from chain), enqueue `ResizeCensusJob` (§5.6) and continue; the chain, not Decidim, enforces the cap by counting votes, as in vocdoni-app. Sign and insert in a savepoint (`requires_new: true`); on `RecordNotUnique`, roll back and re-read: same voter → step 3, address held by another voter → 409 `address_taken`. Return the signature only after commit.
   - `POST …/csp/confirm {questionId}` sets `vote_confirmed_at` after checking chain `GET /v2/votes/{nullifier}`; status lazily re-checks unconfirmed pins.
   - The manifest `voted` block (gem `voting_backend.rb:42`): every question in `election.available_questions` (`election.rb:139-140`) has a confirmed pin.
4. **`per_question`**. The gem sets `supports_per_question = true` (gem `voting_backend.rb:37`). Fork hooks (`demo/integrated-booth`, `decidim-elections/`):
   - `votes_controller.rb:10-12` sends `per_question` elections to `PerQuestionVotesController` before the client-booth redirect (`:16-18`); the `booth` route exists only under `votes` (`lib/decidim/elections/engine.rb:16` vs `:19-23`). Change: skip that redirect when `voting_backend.client?`, so the booth (`uses_votes_booth.rb:72-78`) serves `per_question`.
   - `per_question_votes_controller.rb:18-20,97-106` gate on `voting_enabled?` and serve a JSON poll; the booth mirrors this through `statusUrl`.
   - `application_helper.rb:62-65` (`voted_by_current_user?`) reads `election.votes`; the manifest `voted?` (`voting_backend_manifest.rb:57-61`) has no caller. Change: the helper calls `election.voting_backend.voted?`.
   - `voting_backend_manifest.rb:26` (`supports_per_question`) is not enforced anywhere; no change.
   - `admin/update_question_status.rb:36-42` publishes `decidim.elections.admin.update_question_status:after` (`decidim-core/lib/decidim/command.rb:46-51`). On `publish_results` the gem ends that question's chain election via saas `PUT /processes/{id}/questions/{qid}/status` (`api/routes.go:184-185`) and syncs its results. `enable_voting` needs no hook.
5. **Rate limits and logs**
   - Rack::Attack (decidim-core `rack_attack.rb:3-24`, production only): `/csp/*` 120/min per IP. In the controller: sign 3 per (voter digest, question) per minute, status/confirm 30/min per voter digest, counters in `Rails.cache`.
   - One structured `csp.sign` line per sign or refusal: process, question, voter digest, outcome; **never the address or nullifier**. Log retention (hosting logs, drains) ≤ the purge window (§8).
   - The admin dashboard shows signatures issued per question.
6. **Publish job** (`publish_election_job.rb`)
   - `declare_census!` (replacing `prepare_census!`) counts the roster as `election.census.user_query(election).count`: `Voter.where(election:)` for `token_csv` (fork `engine.rb:60-62`); for `internal_users`, `Decidim::AuthorizedUsers(strict: true)`, i.e. confirmed, non-deleted, non-blocked users holding all the election's handlers (`engine.rb:70-78`). `maxCensusSize` = row count for `token_csv` (frozen after publish, `admin/permissions.rb:53-57`); ceil(roster × 1.20) for `internal_users` (`VOCDONI_CENSUS_HEADROOM`, default 0.20), so small census growth needs no resize or payment; the SaaS prices the declared size, headroom included. `ResizeCensusJob` raises it to ceil(current roster × 1.20) through the SaaS resize endpoint (§6) when the roster grows; it is enqueued at sign time (§5.3) and by an admin "sync census size" action, and it is idempotent and never shrinks the size.
   - Steps: create the process with the external census → map SaaS questions to Decidim questions by an explicit id in question metadata, never by index → persist `vocdoni_question_id`, `csp_root_id`, `pin_secret_id` → derive and `PUT` the roots (§6) → publish → await the job (`processes_publish.go:885-910`) → persist `upstreamId` → `verify_roots!` → state `verified`.
   - `verify_roots!` reads each election from `VOCDONI_CHAIN_API_URL`, never via the SaaS, and requires `censusRoot == public_key(root_id, seed)`, `censusOrigin == EXTERNAL_CSP_ORIGIN`, `dynamicCensus == false`, `anonymous == false`, `maxCensusSize ==` declared size, `organizationId ==` org address. On failure the process is `compromised`, signing stays off, and the admin is told to end it. `SyncProcessJob` repeats the root, origin and `dynamicCensus` checks.
7. **`booth_config`**: drop `credentials`/`contact` (gem `voting_backend.rb:58-59`); add `signUrl`, `statusUrl`, `confirmUrl`, `csrfToken`.
8. **Config**: `VOCDONI_CHAIN_API_URL` (DEV `https://api-dev.vocdoni.net/v2`, LTS `https://api.vocdoni.io/v2`), checked at boot via `GET /chain/info` against the process `chain_id`. All chain reads are server-side.

## 6. SaaS change (saas-backend)

- **Two PRs.** **S1a**: per-question `censusOrigin`/`censusRoot` (#796 `db/types.go:857-866`) through `SetQuestionPublished` and `NewProcessParams.CensusOrigin`, and resize via the per-question root (#796 `processes_admin.go:771-772`), taken from #796 with V3 derivation off. **S1b**: external CSP. #796 and S1b both build on S1a.
- **Explicit flag.** External CSP is `db.Census.ExternalCSP`, never inferred from `censusOrigin` (#796 reads a non-empty origin as "the SaaS signs", `csp/election.go:60-90`). `SetCensus` (which derives `Type` from the 2FA fields, `db/census.go:68,149`) and #796's `assignCensus` (`api/processes_publish_orphans.go:44-52`) must preserve the flag and leave stored external roots untouched.
- **Gate**: org flag `externalCspAllowed`, set by Vocdoni ops only: external CSP hands vote-minting power to the integrator.
- **Census**: `CensusSpec` (`api/apicommon/voting_processes.go:16-41`) gains write-only `externalCsp: {size: N}` → `ExternalCSP=true`, `Size=N`, no members, group or auth/2FA fields, `censusUri` = the Decidim election URL. Combining it with `memberIds`, `groupId`, `authFields`, `twoFaFields`, `anonymous` or `weighted` is a 400.
- **409 `externalCsp`** for an external census on `PUT /processes/{id}/census`, `PUT …/questions/{qid}/census`, `POST …/census/checkout`, the participants endpoints and every CSP handler (`auth/*`, `check`, `sign`, `sign-batch`, `blind-*`, `weight`, `sign-info`). `SignBallot`/`Sign` refuse before reading `censusOrigin`; `census_propagation`/`census_guard` skip it.
- **Roots on the draft**: `PUT /processes/{id}/external-csp {"censusRoots":{"<questionObjectId>":"<33-byte hex>"}}`, admin role, draft only, stored per `VotingProcessQuestion`; replacing the question set clears them. `POST …/publish` keeps its empty body (`api/processes_publish.go:285-345`). `publishPreflightProblems` refuses any question without a root. The worker, the checkout webhook (`:258`, `:365-370`) and stale-publish reconciliation (`:100-160`) read the stored roots. An external-CSP process **never** falls back to the SaaS key (`:493`).
- **Validation**: one root per question; valid compressed points (`checkCSPKeyCensusRoot`); pairwise distinct; none a SaaS CSP key; `1 ≤ size ≤ /chain/info.maxCensusSize`; census not `anonymous` (`db/types.go:336-338`).
- **Publish**: `cspPubKey`/`census.Published` (`:493-500`) take the per-question root; `electionParamsForQuestion` (`:72`) uses `census.Size`; `dynamicCensus` stays false.
- **Origin**: `EXTERNAL_CSP_ORIGIN`, default `OFF_CHAIN_CA_V2`; `OFF_CHAIN_CA_V3_ECDSA` (enum 5, #796 `electionkey.go:64`) when sequencer #13 deploys.
- **Pricing**: `processQuoteInput` (`api/processes_price.go:24-38`) uses `CensusSize = size`, no 2FA add-ons; the wallet debit is unchanged (`processes_publish.go:473`).
- **Resize**: `POST /processes/{id}/external-csp/size {size}`, priced like census growth, reusing `setProcessCensusSizes` (`api/processes_admin.go:1176-1220`). It sends `SET_PROCESS_CENSUS` with the question's own root, equal to the on-chain one, so the DynamicCensus gate does not apply (§3); never `census.Published.Root` (`:1225-1228`).
- **Unchanged**: vote relay (`api/process_vote.go:415-431`), results, status/end, encryption keys.
- **Tests** (voconed): publish via API, webhook and reconciliation keeps the roots; test-root vote accepted, wrong root rejected; 409 routes; resize keeps the root; the V2 weight-`01` fixture.

## 7. Voter JS change (gem `voter/*` → `public/vocdoni/booth-adapter.js`)

- **Remove**: `createAuthSession`, OTP (`booth_adapter.js:61-121`), the `pre_ballot_partial`, `processes.check` (`flow.js:139`), `processes.sign` (`cast.js:131`), `signInfo` (`flow.js:182`).
- **Keep**: `elections.get`, `getQuestion`, `EphemeralSigner`, `jobs.waitFor`, and `votingClient.vote` with **`proofType: ProofCA_Type.ECDSA`** (default `ECDSA_PIDSALTED`, `@vocdoni/api-voting@1.2.1` `src/vote-transaction.ts:98`) and `cspWeight: "01"`.
- **Add**:
  - `prepare` calls `statusUrl`; `cast` calls `signUrl` per question, then `confirmUrl` after the job completes;
  - `receipts` and `recheck` (`booth_adapter.js:171,179,255-265`) read `statusUrl`; `recheck` first POSTs `confirmUrl` for unconfirmed pins;
  - `upstreamId` comes only from `booth_config` (`vocdoni_upstream_id`);
  - `per_question`: show only questions with `votingEnabled`, polling `statusUrl` for the next;
  - receipt nullifier = `keccak256(address ‖ upstreamId)`.
- **Ephemeral key**: client-generated, no recovery, as in vocdoni-app. Kept in `sessionStorage` per (upstreamId, questionId) from before sign until the job completes, so a retry reuses the pinned address. A voter who loses it gets 409 `address_pinned` and is locked out ("contact the organiser"); no re-vote, no overwrite.

## 8. Threat model (pilot vs today)

| Threat | Today (SaaS CSP) | Decidim CSP (pilot) |
|---|---|---|
| Key compromise | The SaaS global key mints in every SaaS CSP election. | A root mints in every open election derived from it, up to `maxCensusSize` minus votes. Mitigations: env-only, per-environment roots; end and republish. |
| Operator abuse | SaaS operators can mint. | Decidim root holders can mint up to `maxCensusSize`; the SaaS cannot. |
| Decidim app compromise: `secret_key_base` holders, DB writers, code deploy, impersonation | n/a | `voter_uid` comes from the Rails session, so forged sessions, changed credentials, inserted `Voter` rows or granted authorizations get signatures for every voter who has not voted, without the root. Not prevented; only Decidim access control and admin logs mitigate it. |
| Double voting | Address pinned per member (`csp/sign.go:259`). | Pin per (voter digest, question) plus one vote per address on chain. Strength = uniqueness of the voter key: per Decidim account admitted by the census (as per memberbase entry in vocdoni-app); per CSV row for `token_csv`. Residual: several admitted accounts of one person vote several times. |
| Replay | processId (with chainId prefix) is in the bundle. | Same, plus a distinct key per election. |
| Voter ↔ ballot link | The SaaS stores user → address. | Pins hold digest → address, equivalent. `PurgeCspPinsJob` clears `address` and `nullifier` 30 days after results, keeping digest, `vote_confirmed_at` and counts. **Not anonymous towards Decidim; the pilot organisation must be told.** |
| Logs | n/a | Digest only, never address or nullifier; retention ≤ purge window. A pin-secret holder with the user list can reverse digests. |
| SaaS publishes a wrong root or `dynamicCensus:true` | n/a | `verify_roots!` catches it before any signature; later root changes are impossible. With the org key the SaaS can still end, pause, cancel, resize or censor relayed votes: visible on chain, not prevented. |

**Public audit.** Per question, Decidim publishes the root, `maxCensusSize`, signatures issued, optionally the signed addresses, and at close the admitted census count (`internal_users`: users passing the census check; `token_csv`: rows). Checks: `votes ≤ signatures ≤ maxCensusSize`, `signatures ≤ admitted count`, every vote signer in the list. These catch a leaked root used by an outsider who writes no pins. They **cannot detect minting by the Decidim operator**, who controls both signatures and lists.

## 9. Path to blind V3

When the CSP malleability fix lands, the origin moves to `V3_BLIND`. Decidim derives `dB` (`election-blind`) and `dX` (`weight-key`) and issues the weight certificate (`electionkey.go:204-221`; vectors in the same JSON). Two session-authenticated rounds (R point, blind-sign) replace `/sign`, and the pin is marked consumed with no address. Blind math runs on OpenSSL BN/EC. Keyring, pin secret, seeds, table and SaaS mode stay.

## 10. Rollout and milestones

The 2026-11-11 demo keeps the SaaS CSP; this doc is the pilot plan. First pilot, December (dates TBC):

| Week | Item |
|---|---|
| Nov 9–13 | S1a; gem keyring, pin secret, vectors (G1) |
| Nov 16–20 | S1b (flag, roots on draft, 409 routes, resize); gem pins, endpoints, `verify_roots!`, `per_question` hooks, publish job (G2–G3), booth adapter (G4) |
| Nov 23–27 | S1a+S1b on a dev SaaS instance; e2e on DEV/36 **and** a sequencer/LTS-like chain such as staging: multi-question, encrypted, `per_question`, dynamic census, census growth → resize, `address_pinned`; request the LTS backport; prod secrets and chain URL |
| Dec | LTS SaaS backport merged by the release owner; pilot |

**Go/no-go**: S1a+S1b on the LTS SaaS and a passing sequencer/LTS-like e2e. December is feasible if both PRs reach saas `main` by Nov 20 and the release owner backports them; neither is in this team's control.

### Risks and dependencies

| Dependency | Owner | Risk |
|---|---|---|
| LTS SaaS backport of S1a+S1b | Release owner (owner-chosen cherry-picks only) | Not merged in time: no pilot on LTS. |
| Sequencer #13 retiring V2 | CSP-epic flag-day owner | Check whether #13 reaches LTS at the cutover; if so, flip `EXTERNAL_CSP_ORIGIN` to V3_ECDSA in the same window. |
| Sequencer/LTS-like e2e | This team | DEV/36 shares only the verifier, not the publish/vote/API path. |
| #796 vs S1a order | saas-backend owner | §11 Q4. |

The roster count is specified in §5.6; nothing depends on gem PR #53.

## 11. Owner decisions

Decided by the owner:

1. **OTP:** not required for the first pilot, so the pilot ships without it. OTP is a core Vocdoni feature and the Decidim offer loses much of its value without it, so it is the first follow-up after the pilot path is green: Decidim sends the code (email first, SMS later) before the sign endpoint accepts a request, reusing the SaaS notification service if it can be exposed to integrators.
2. **Custody:** the prod root and pin secret are custodied by Vocdoni ops in the secret store of the Decidim instance we run.
3. **Roots:** one root per Decidim instance.
4. **Merge order:** S1a first; #796 rebases onto it.
5. **Voter key and census cap (vocdoni-app parity):** the `internal_users` voter key is the Decidim account (`voter_uid`), with no authorization handler required. The census cap is the roster size at publish plus a default 20% headroom (priced at publish), with no pin expiry; the chain counts votes, and only growth past the headroom triggers a resize through the SaaS endpoint, charged then.

## Beyond parity (team-level; vocdoni-app first)

- Lost ephemeral key recovery or re-vote: not designed; voters are locked out as in vocdoni-app.
