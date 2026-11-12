Status: abandoned 2026-11-09 — superseded by the integrator-attested census (vocdoni/saas-backend#858, vocdoni/decidim-secure_elections#69). Code: branch `abandoned/decidim-as-csp` in the repos above.

# Decidim as external CSP: implementation plan

Design: see the companion design document on the same branch (§11 owner decisions are binding). This plan follows it except where marked **Design deviation**.

## Header

**Goal.** Decidim signs each eligible voter's ephemeral address with a per-question key derived from a root it alone holds. The SaaS stores per-question public roots and the declared census size, publishes `OFF_CHAIN_CA_V2` elections with them, relays votes and never signs.

| Repo | Base | Branch |
|---|---|---|
| saas-backend | `origin/main` `abc28929aa51e9307fbc52ba02e1e6f7c966f90a` | S1a `feat/csp-per-question-roots`; S1b `feat/external-csp` stacked on S1a |
| gem `vocdoni/decidim-secure_elections` | `origin/demo/integrated-booth` `34e34762e3f0978c2fecec89bcc44cd297e924a0` | `feat/external-csp` |
| fork `vocdoni/decidim` | `origin/demo/integrated-booth` `55b213e9bdae1dfa3eda04bcd5ac523085d3cbd5` | `feat/external-csp` |

Reference: PR #796 head `8db6b81f…`, which is 16 commits ahead of and 26 behind main. It is a source for hand-ports, not for cherry-picks.

**Tasks** (tasks within a group run in order; groups run in parallel):

| Task | Depends on |
|---|---|
| T1 S1a per-question census origin/root | — |
| T2 S1b V2 weight-01 fixture | T1 |
| T3 S1b model, flag, roots-on-draft API | T2 |
| T4 S1b publish, 409 guard, resize | T3 |
| T5 G1 crypto, keyring, pin secret | T2 (fixture JSON only; vectors part can start at once) |
| T6 G2 schema: csp_elections, pins, trigger | T5 |
| T7 G2 VoterCspController, ChainClient, ResizeCensusJob skeleton | T6 |
| T8 G3 publish job, verify_roots!, resize job body, sync | T7, T3 contract, T4 contract |
| T9 G3 manifest, per-question end, purge, admin count, Security tab | T8 |
| T10 G4 booth adapter JS | T7 contract, T2 fixture |
| T11 fork hooks (per_question booth, voted?, per-question votes guard) | — |
| T12 E2E on the dev Decidim instance against the dev SaaS / DEV/36 | T4, T9, T10, T11 |

T1–T4 (SaaS), T5–T10 (gem) and T11 (fork) start on day 1. T5's vector specs need nothing. The T2 fixture is copied into the gem once T2 has committed it, which takes about half a day. T7 owns `ChainClient` and a no-op `ResizeCensusJob#perform(process_id)`, so its specs load without T8; T8 fills in the job body. The "T3/T4 contract" dependencies are the request/response shapes written in T3 and T4 (T8 stubs them with WebMock), not merged code.

## Design deviations (found against the code)

1. **Table name.** The gem prefix is `table_name_prefix = "decidim_vocdoni_"` (`lib/decidim/elections/vocdoni.rb`), so the tables are `decidim_vocdoni_csp_pins` and `decidim_vocdoni_csp_elections`, not `decidim_elections_vocdoni_csp_pins`.
2. **`verified`/`compromised` cannot live in `Process.state`.** `SyncProcessJob#derive_state` (`sync_process_job.rb:125-134`) rewrites `state` on every tick. `extract_questions_meta` (`:137`) also rebuilds `metadata["questions"]` by index, and a unique index cannot sit inside jsonb. The plan therefore:
   - adds a separate `csp_state` column (`nil|verified|compromised`);
   - adds a `decidim_vocdoni_csp_elections` table, unique on `seed` and on `decidim_question_id`;
   - maps SaaS questions by question `metadata.decidimQuestionId`, never by index (both jobs).
3. **`checkCSPKeyCensusRoot` does not exist** in main or in #796. T3 adds `csp/externalcsp.ParseRoot`, which requires a 33-byte, `0x02`/`0x03`-prefixed point that decompresses on the curve via `ethcrypto.DecompressPubkey`.
4. **Resize vs `POST …/census/checkout` → 409 is contradictory.** A resize past the paid size gets a 402, and that 402 can only be paid through `census/checkout` (`processes_census_payment.go:141`, `:200+`, which buys headroom by `censusSize` only and touches no members). So `census/checkout` **stays open** for external CSP. It is removed from the 409 list.
5. **`csrfToken` in `booth_config` is impossible.** The block receives `(election, voter_uid:, current_user:)` and has no controller or session. The booth layout renders `layouts/decidim/head` with the `csrf-token` meta tag, so the JS reads that tag.
6. **Stale #796 / design line refs.**
   - The #796 resize hunk (`processes_admin.go:771-772`) targets an older layout; on main the target is `submitSetProcessCensus` (`:1224-1242`).
   - The "checkout webhook `:258`, `:365-370`" is `processes_publish_payment.go:820` → `startProcessPublish` (`processes_publish.go:370`), checked against `abc28929` with `git grep -n 'startProcessPublish('`.
   - `VotingProcessQuestion` is at `db/types.go:1111-1149` on main.
   - **S1a is a hand port, not a cherry-pick.**
7. **Config and detail fixes.**
   - The env var follows the repo's underscore convention (`disable_blindcsp` → `VOCDONI_DISABLE_BLINDCSP`): `VOCDONI_EXTERNAL_CSP_ORIGIN` (flag `external_csp_origin`).
   - "Prod chain" for the root denylist is decided by the `chainId` that the chain API returns, not by the URL string. `GET {VOCDONI_CHAIN_API_URL}/chain/info` answers `api.ChainInfo` with `ChainID string \`json:"chainId,omitempty"\`` (vocdoni-node `api/api_types.go:66`, handler `api/chain.go:505`; the same field in vochain-sequencer `api/api_types.go:66`). LTS chain ids are `vocdoni/LTS/<version>`: the `networks` map in vocdoni-node `vochain/genesis/genesis.go` has `"lts": "vocdoni/LTS/1.3"`, and vochain-sequencer `config/forks.go:19` keeps the same id. DEV is `vocdoni/DEV/36` and stage is `vocdoni/STAGE/<n>`. A chain id that starts with `vocdoni/LTS/` is the prod chain. The gem's `process.chain_id` is the SaaS echo of the same value (`sync_process_job.rb` `persist!`, `remote["chainId"]`).
   - The denylist is enforced where a chain id is known, before any signature: at publish (`record_csp_ids!`) and in `verify_roots!`. Boot does not check it, because no process exists at boot and boot does no chain I/O (design §4 has prod refuse to start instead).
   - `VOCDONI_CHAIN_API_URL` has no default in production. Without it, the guarded boot check and the lazy `csp_ready!` raise `ConfigurationError`, so a prod deploy cannot fall back to the dev chain.
   - The `chain_id` check moves from boot into `verify_roots!`, because no process exists at boot.
   - Per-question `publish_results` ends that question with `bulk_set_question_status(process_id, status: "ENDED", question_ids: [qid])`.
8. **Voter key for `internal_users`.** `voter_uid` is a GlobalID string (`gid://<app-name>/Decidim::User/<id>`, `internal_users_form.rb:16`). The app name is part of it, so renaming the app would change every digest and allow a second pin. The key uses the parsed model id instead:
   - `"user:<election_id>:<User.id>"`;
   - `"row:<election_id>:<Voter.id>"` for `token_csv`.

   Both are parsed with `GlobalID.parse`.
9. **Demo timing.** Merging the gem and fork branches into `demo/integrated-booth` removes the SaaS CSP/OTP booth path. They merge only **after the 2026-11-11 demo**, with owner OK.

10. **Census headroom.** `maxCensusSize` at publish and on resize is ceil(roster × (1 + `VOCDONI_CENSUS_HEADROOM`)), with the env default 0.20, for `internal_users`. `token_csv` keeps the exact row count, because its census is frozen after publish. The headroom is priced at publish by the SaaS like any declared size. `ResizeCensusJob` fires only when the roster exceeds the current on-chain size. Applies to T5 (the `Vocdoni.census_headroom` accessor: parsed as a `Rational`, `0 ≤ h ≤ 1`), T8 (`Vocdoni.declared_census_size`, computed in `Rational` because `5 * 1.2` is `6.000000000000001` in Float and its ceil is 7) and T12.
11. **Roster count API.** Design §5.6 counts the roster with `election.census.user_query(election).count`, but the fork's `CensusManifest#user_query(&block)` only registers a block (`decidim-elections/lib/decidim/elections/census_manifest.rb:49-51`). The count is `election.census.count(election)` (`census_manifest.rb:86-93`): `Voter.where(election:)` for `token_csv`, `AuthorizedUsers(strict: true)` for `internal_users`. Applies to T7 and T8.
12. **The census size is not a compromise check.** Design §5.6 lists `maxCensusSize ==` declared size among the `verify_roots!` checks. A chain size below `census_size` only means a resize has not mined yet (the SaaS can censor anyway; only Decidim can mint), so a size mismatch logs a WARN and enqueues `ResizeCensusJob`; it never sets `compromised`. Root, origin and `dynamicCensus` mismatches (and, in `verify_roots!` only, `anonymous`, organisation and `chain_id`) set `compromised`. `census_size` is the size Decidim has confirmed on chain, so the sync job never overwrites it from the SaaS for external-CSP processes. Applies to T8.

## Global constraints

- Build, test, lint and bundle on the build host only, not on a local development machine.
- **Ruby/JS**: work in its own clone. Gem specs need `bundle exec rake test_app` once per clone; the DB name derives from the directory. Run every gem command with `DECIDIM_PATH=<fork checkout on \`feat/external-csp\`>`, checked out on `feat/external-csp` (on `demo/integrated-booth` until T11 has committed), so the gem runs against the fork's hooks. Use `DATABASE_HOST/USERNAME/PASSWORD` from the environment. If `rake test_app` takes more than about 20 min, report the error.
  - **Fork test app.** Fork specs need `cd decidim-elections && bundle exec rake test_app` once per clone.
  - **Gem migrations.** `rake test_app` copies the gem migrations once. A task that adds migrations (T6) runs `cd spec/decidim_dummy_app && bin/rails decidim_elections_vocdoni:install:migrations && bin/rails db:migrate RAILS_ENV=test`; a host app (T12) runs `bin/rails decidim_elections_vocdoni:install:migrations && bin/rails db:migrate`.
  - Do not touch the live dev app or other work dirs.
- **Go**: clone `vocdoni/saas-backend`. Use `go test ./<pkg>/ -run <Name> -count=1` per task and `make test` before the PR. Run `make lint` (golangci-lint).
- **Commits.** Conventional `type(scope): lowercase summary`. No AI attribution, no Co-Authored-By. Explicit paths only (`git add <file> …`, never `-A`/`.`).
- **Comments and docs** say what is and why, never history ("was", "previously", "moved from").
- **Secrets.** Never print roots, the pin secret, `.env` contents or tokens. Generate secrets straight into files with `umask 077`. Logs carry `csp_root_id` / `pin_secret_id` only. Test roots are the public vector root and fresh random keys inside specs.
- **Never log the address.** The gem's own log lines carry the voter digest only, and the engine adds `:address, :nullifier, :pinnedAddress` to `Rails.application.config.filter_parameters`, so Rails request logs print `[FILTERED]` (T7).
- **Boot checks only when serving.** CSP boot checks (OpenSSL, keyring, pin secret, chain URL, pins trigger) run only in a serving process: `Rails.const_defined?(:Server)`, `VOCDONI_CSP_BOOT_CHECK=1` (set in the web start command only, never service-wide) or `Sidekiq.server?`. `db:migrate`, `assets:precompile`, `rails runner` and the console work with no CSP secrets set. The first sign and the first publish re-check lazily through `Vocdoni.csp_ready!` (T5, T6).
- **Census headroom.** `VOCDONI_CENSUS_HEADROOM` (default `"0.20"`) is parsed as a `Rational` and must satisfy `0 ≤ h ≤ 1`, else `ConfigurationError` (T5). Never compute the size in Float (deviation 10).
- **API-key allowlist.** `api/apikeys.go` `apiKeyAllowlist` is deny-by-default (`api/middlewares.go:232-238` answers `ErrAPIKeyNotAllowed`), and the gem calls the SaaS with a `vsk_` key. Every new SaaS route the gem calls gets an allowlist entry and an `api/apikeys_test.go` case in the task that adds the route (T3, T4).
- **PR bodies.** About 10–20 lines covering what, why and how verified. No test-plan checklist.
- RuboCop, ESLint and golangci-lint must pass on touched files.

## Review focus (for every reviewer)

1. **Pin invariant.** No code path produces a second pin for the same (voter digest, question), or a second address for a pin:
   - unique indexes `(decidim_question_id, voter_digest)` and `(decidim_question_id, address) WHERE address IS NOT NULL`;
   - a DB trigger forbids DELETE and identity changes, and lets address/nullifier change only to NULL;
   - the sign path uses a savepoint plus RecordNotUnique re-read;
   - adding a keyring root changes neither digests nor the 409.
2. **59-byte bundle.** `0a20‖pid32‖1214‖addr20‖1a0101`. The digest uses the computed length (`\n59`). The Ruby bundle equals `encodeCaBundle({processId,address,weight:"01"})` and the Go fixture byte for byte.
3. **Low-s, RFC 6979.** `s ≤ n/2`, with v flipped when s is negated, and v ∈ {0,1}. The Ruby signature equals the vector and the Go `crypto.Sign` output byte for byte.
4. **Pin secret vs keyring separation.**
   - Different env vars; boot refuses a pin secret equal to any root.
   - `pin_secret_id` is recorded per process and checked on sign (`pin_secret_mismatch`).
   - Roots never touch the DB, `secret_key_base` or logs.
   - Signing uses the root recorded on the process and never falls back to "newest" (`csp_root_missing`).
5. **409 routes.** Every SaaS member/CSP route on an external-CSP census answers 409 40185, and the SaaS never signs or falls back to its own key. `census/checkout` and `external-csp/size` stay open (deviation 4), and both new external-CSP routes are on the API-key allowlist.
6. **verify_roots!** reads the chain directly, never via the SaaS. No signature is issued unless `csp_state == "verified"`. A census-size mismatch never sets `compromised` (deviation 12).

## Test vectors

- `csp-v3-vectors.json`, taken byte-identical from #796 `csp/signers/electionkey/testdata/csp-v3-vectors.json` at `8db6b81f`. Copy it with `gh api repos/vocdoni/saas-backend/contents/csp/signers/electionkey/testdata/csp-v3-vectors.json?ref=8db6b81f… -H 'Accept: application/vnd.github.raw'`. Keys used:
  - `root` `8f1d3c5e…c4d5`;
  - `voter.private` `4c0883a6…2318` / `voter.public` `024e3b81…`;
  - `elections[0].seed` `65f0a1b2c3d4e5f60718293a` → `electionEcdsaKey.private` `49b0e84a…97b8`, `.public` `02886e8c…46bd`;
  - `elections[1].seed` `…293b` → `.public` `0399343c…f5cd`;
  - `proofs[0]` ("ecdsa weight 42"): `processId` `c0ffee000001…aa0500000000000001`, `address` `2c7536e3605d9c16a7a3d7b1898e529396a65c23`, `voteWeight` `2a`, `bundle`, `signature` `4cfe08ba…b201`.
- Destinations:
  - saas S1b `csp/externalcsp/testdata/csp-v3-vectors.json`;
  - gem `spec/fixtures/csp/csp-v3-vectors.json`.
- `csp-external-v2-ecdsa.json` (generated by T2, committed in saas `csp/externalcsp/testdata/`, copied byte-identical to gem `spec/fixtures/csp/`). Fields:
  - `censusOrigin`: `"OFF_CHAIN_CA_V2"`, `proofType`: `"ECDSA"`;
  - `root`: vectors root; `seed`: seed0;
  - `censusRoot`: `02886e8c…46bd`; `wrongCensusRoot`: seed1 public;
  - `processId`: `c0ffee0000010000000000000000000000000000000000aa0400000000000001`;
  - `address`: vectors voter address; `voteWeight`: `"01"`;
  - `bundle` (59 bytes, hex), `digest`, `signature` (65 bytes, hex), `nullifier` = keccak(address‖processId).

## Tasks

### T1 — S1a: per-question census origin and root (saas)

Branch `feat/csp-per-question-roots` from `abc28929`. This is a behaviour-preserving port of #796's shape with V3 derivation off: legacy elections keep empty per-question origin/root.

Files:
- `db/types.go` — `VotingProcessQuestion` (`:1111-1149`): add after `SyncedAt` (`:1128`):
  ```go
  // CensusOrigin is the census origin name of this question's election when its census root is
  // its own rather than the SaaS CSP key, and CensusRoot that root. Both are empty for an election
  // on the SaaS CSP key.
  CensusOrigin string            `json:"-" bson:"censusOrigin,omitempty"`
  CensusRoot   internal.HexBytes `json:"-" bson:"censusRoot,omitempty"`
  ```
- `db/processes_questions.go` — replace `SetQuestionPublished(id, upstreamID, metadataURL, status)` (`:221-238`) with #796's `QuestionPublishedParams{ID, UpstreamID, MetadataURL, Status, CensusOrigin, CensusRoot}`:
  - `ErrInvalidData` when ID is nil, UpstreamID is empty, or exactly one of origin/root is set;
  - `$set` adds `censusOrigin`/`censusRoot` only when set.

  Check that `ResetQuestionsPublish` (`:297-312`) never unsets a mined question's origin/root (it only touches unmined ones; add `censusOrigin`/`censusRoot` to its `$unset` for unmined questions).
- Update every caller: `api/processes_publish.go:766` and the tests `db/voting_processes_test.go`, `db/census_revocation_test.go`, `api/processes_publish_state_test.go`, `api/processes_end_date_test.go`, `api/processes_blind_csp_switch_test.go`, `api/census_sync_test.go`. Use `rg -n 'SetQuestionPublished\(' --type go` to confirm the list.
- `account/process.go` — `NewProcessParams`: replace `Anonymous bool` with `CensusOrigin models.CensusOrigin` (doc as #796 minus V3). Add `isCSPCensusOrigin` (`OFF_CHAIN_CA`, `OFF_CHAIN_CA_V2` only). In `BuildNewProcessTx` (`~:225-230`), replace the anonymous switch with:
  ```go
  if !isCSPCensusOrigin(p.CensusOrigin) {
      return nil, fmt.Errorf("census origin %d is not a CSP census origin", p.CensusOrigin)
  }
  ```
  and set `CensusOrigin: p.CensusOrigin`.
- `api/processes_publish.go`:
  - Add to the worker:
    ```go
    // assignCensus returns the census origin, root and URI of q's election. A census on the SaaS CSP
    // key publishes OFF_CHAIN_CA (OFF_CHAIN_CA_V2 with its blind key when anonymous) and leaves the
    // question's own origin and root empty.
    func (pw *publishWorker) assignCensus(q *db.VotingProcessQuestion) (models.CensusOrigin, []byte, string, error) {
        origin := models.CensusOrigin_OFF_CHAIN_CA
        if pw.census.Anonymous {
            origin = models.CensusOrigin_OFF_CHAIN_CA_V2
        }
        return origin, pw.cspPubKey, pw.a.serverURL, nil
    }
    ```
  - In `buildBatch` (`:1045-1047`), call it and pass `CensusRoot: root, CensusURI: uri, CensusOrigin: origin`.
  - `persistPublished` (`:748-775`) passes `QuestionPublishedParams{…, CensusOrigin: q.CensusOrigin, CensusRoot: q.CensusRoot}`. Check `flushMinedUnpersisted` routes through `persistPublished` with the same `q`.
- `api/processes_admin.go`:
  - add #796's `questionCensusRoot(q, census) ([]byte, error)` (own root if set, else `csp.PubKey()` / `BlindPubKey()` when anonymous). It returns an error rather than a root so that T4's external branch can refuse instead of falling back; in T1 the error is always nil;
  - `submitSetProcessCensus` (`:1224-1242`) uses it instead of `t.census.Published.Root` and fails that target on error;
  - `t.census.Published.URI` stays.
- `account/process_test.go:71-82`: `newParams` in `TestBuildNewProcessTxInitialStatus` sets no `CensusOrigin`, so the new validation would break `-run TestBuildNewProcessTx`. Add `CensusOrigin: models.CensusOrigin_OFF_CHAIN_CA`.
- Tests:
  - `db`: `TestSetQuestionPublishedCensusOrigin` (from #796): both set → stored; one set → `ErrInvalidData`; none → fields absent.
  - `account`: `TestBuildNewProcessTxCensusOrigin`: OFF_CHAIN_CA / V2 accepted and carried into the tx; 0 and `OFF_CHAIN_TREE` refused.
  - `api`: `TestQuestionCensusRootPrefersOwnRoot` (own root wins; legacy falls back to the key, or the blind key when anonymous).

**Rebase note for #796.** S1a's shapes differ from #796's: #796 defines `assignCensus(q) (models.CensusOrigin, error)` in `api/processes_publish_orphans.go:44`, where T1 returns `(origin, root, uri, error)` from the publish worker, and #796 `db/processes_questions.go:219-258` has its own `QuestionPublishedParams`. When #796 rebases onto S1a (owner decision 4) it adopts S1a's signatures; state this in the S1a PR body so the #796 author does not resolve the conflict the other way.

Commands:
```
go test ./db/ -run 'TestSetQuestionPublished' -count=1          # ok  github.com/vocdoni/saas-backend/db
go test ./account/ -run 'TestBuildNewProcessTx' -count=1       # ok
go test ./api/ -run 'TestQuestionCensusRoot|TestPublish|TestBlindCSPSwitch|TestEndDate|TestCensusSync' -count=1   # ok
make test && make lint                                         # all ok, 0 issues
```
Commit: `feat(processes): carry per-question census origin and root through publish and resize`.

### T2 — S1b: V2 weight-01 fixture and root parser (saas)

Branch `feat/external-csp` from T1's head.

Files:
- `csp/externalcsp/root.go`:
  ```go
  // Package externalcsp holds what the SaaS checks about census roots it does not own: an
  // integrator signs the proofs of these elections with keys the SaaS never sees.
  package externalcsp

  // RootSize is the length of a compressed secp256k1 public key.
  const RootSize = 33

  // ParseRoot returns root when it is a compressed secp256k1 point on the curve.
  func ParseRoot(root []byte) ([]byte, error) {
      if len(root) != RootSize || (root[0] != 0x02 && root[0] != 0x03) {
          return nil, fmt.Errorf("census root is not a 33-byte compressed public key")
      }
      if _, err := ethcrypto.DecompressPubkey(root); err != nil {
          return nil, fmt.Errorf("census root is not a secp256k1 point: %w", err)
      }
      return root, nil
  }
  ```
- `csp/externalcsp/root_test.go`: the vector public key is accepted; length 32/65, prefix `0x04` and an off-curve x are refused.
- `csp/externalcsp/testdata/csp-v3-vectors.json` (byte copy, see Test vectors).
- `csp/externalcsp/fixture_test.go`:
  ```go
  package externalcsp_test

  var update = flag.Bool("update", false, "rewrite testdata/csp-external-v2-ecdsa.json")

  const tagElectionECDSA = "vocdoni/csp/v3/election-ecdsa"

  // hashToScalar mirrors the per-election key derivation the integrator implements.
  func hashToScalar(tag string, data []byte) *big.Int {
      n := ethcrypto.S256().Params().N
      var c [4]byte
      for i := range 256 {
          binary.BigEndian.PutUint32(c[:], uint32(i))
          h := new(big.Int).SetBytes(ethcrypto.Keccak256([]byte(tag), c[:], data))
          if h.Sign() > 0 && h.Cmp(n) < 0 {
              return h
          }
      }
      panic("no scalar")
  }

  func TestExternalCSPV2Fixture(t *testing.T) {
      c := qt.New(t)
      // read vectors: root, voter.public, elections[0..1].seed, elections[0].electionEcdsaKey.private
      d := hashToScalar(tagElectionECDSA, append(root, seed0...))
      c.Assert(hex.EncodeToString(math.PaddedBigBytes(d, 32)), qt.Equals, vec.Elections[0].ElectionEcdsaKey.Private)
      key, _ := ethcrypto.ToECDSA(math.PaddedBigBytes(d, 32))
      censusRoot := ethcrypto.CompressPubkey(&key.PublicKey)

      pid, _ := hex.DecodeString("c0ffee0000010000000000000000000000000000000000aa0400000000000001")
      voterPub, _ := hex.DecodeString(vec.Voter.Public)
      vid := state.NewVoterID(state.VoterIDTypeECDSA, voterPub)
      addr := vid.Address()
      bundle := &models.CAbundle{ProcessId: pid, Address: addr, VoteWeight: []byte{1}}
      raw, err := proto.Marshal(bundle)
      c.Assert(err, qt.IsNil)
      c.Assert(len(raw), qt.Equals, 59)
      want := append(append(append(append([]byte{0x0a, 0x20}, pid...), 0x12, 0x14), addr...), 0x1a, 0x01, 0x01)
      c.Assert(raw, qt.DeepEquals, want)
      sig, err := ethcrypto.Sign(ethereum.Hash(raw), key) // RFC 6979, low-s, v in {0,1}
      c.Assert(err, qt.IsNil)

      env := &models.VoteEnvelope{ProcessId: pid, Proof: &models.Proof{Payload: &models.Proof_Ca{Ca: &models.ProofCA{
          Type: models.ProofCA_ECDSA, Bundle: bundle, Signature: sig}}}}
      v := &cspproof.ProofVerifierCSP{V2: true}
      ok, w, err := v.Verify(&models.Process{CensusRoot: censusRoot, CensusOrigin: models.CensusOrigin_OFF_CHAIN_CA_V2}, env, vid)
      c.Assert(err, qt.IsNil); c.Assert(ok, qt.IsTrue); c.Assert(w.Int64(), qt.Equals, int64(1))
      // the other seed's root must not verify
      ok, _, _ = v.Verify(&models.Process{CensusRoot: wrongRoot, CensusOrigin: models.CensusOrigin_OFF_CHAIN_CA_V2}, env, vid)
      c.Assert(ok, qt.IsFalse)
      // fixture: write with -update, otherwise compare byte for byte with the committed file
  }
  ```
  `wrongRoot` is derived from seed1 and asserted equal to `elections[1].electionEcdsaKey.public`. `nullifier = ethcrypto.Keccak256(addr, pid)`. Write the JSON with `json.MarshalIndent(…, "", "  ")` plus a trailing newline. Use stdlib `encoding/hex` lowercase without `0x`.

Commands:
```
go test ./csp/externalcsp/ -run TestExternalCSPV2Fixture -update -count=1   # writes testdata/csp-external-v2-ecdsa.json
go test ./csp/externalcsp/ -count=1                                         # ok (fixture matches)
```
Commit: `test(csp): add external csp root parser and v2 ecdsa weight-01 fixture`.

### T3 — S1b: org flag, external census, roots on the draft (saas)

Files:
- `db/types.go`:
  - `Organization` (`:93`): `ExternalCSPAllowed bool \`json:"-" bson:"externalCspAllowed,omitempty"\``, set by Vocdoni ops only (mongosh) and with no API writer.
  - `Census` (`:331-347`): `ExternalCSP bool \`json:"externalCsp,omitempty" bson:"externalCsp,omitempty"\`` and `ExternalCSPURI string \`json:"externalCspUri,omitempty" bson:"externalCspUri,omitempty"\``.
  - `VotingProcessQuestion`: `ExternalCSPRoot internal.HexBytes \`json:"-" bson:"externalCspRoot,omitempty"\``.

  `SetCensus` (`db/census.go:40-84`) uses `dynamicUpdateDocument`, which skips zero fields, so `true` persists and later writes cannot drop it. Add a db test asserting that a second `SetCensus` (size change) keeps `ExternalCSP` and `ExternalCSPURI`.
- `db/processes_questions.go`: `SetQuestionsExternalCSPRoots(processID bson.ObjectID, roots map[bson.ObjectID]internal.HexBytes) error`. It runs one `UpdateOne` per question with filter `{_id, processId, upstreamId: {$exists: false}}`, and returns `ErrNotFound` if any matched 0.
- `errors/errors_definition.go`:
  ```go
  ErrExternalCSP           = Error{Code: 40185, HTTPstatus: http.StatusConflict, Err: fmt.Errorf("the census of this process is held by an external CSP")}
  ErrExternalCSPNotAllowed = Error{Code: 40186, HTTPstatus: http.StatusForbidden, Err: fmt.Errorf("the organization may not use an external CSP")}
  ```
- `api/apicommon/voting_processes.go`:
  - `CensusSpec` gains `ExternalCSP *ExternalCSPSpec \`json:"externalCsp,omitempty"\``, with `ExternalCSPSpec{Size int64 \`json:"size"\`; CensusURI string \`json:"censusUri"\`}`. Reads echo it from `census.ExternalCSP`/`Size`/`ExternalCSPURI`.
  - New request `SetExternalCSPRootsRequest{CensusRoots map[string]internal.HexBytes \`json:"censusRoots"\`}` and `ExternalCSPSizeRequest{Size int64 \`json:"size"\`}`.
- `account/account.go`: `ChainMaxCensusSize() (uint64, error)` via `a.client.ChainInfo()` → `MaxCensusSize`.
- `api/processes_census.go` `resolveOrCreateDefaultCensus` (`:48-110`): when `spec.ExternalCSP != nil` → `a.resolveExternalCSPCensus(spec, orgAddress)`. It validates, then creates `Census{OrgAddress, ExternalCSP: true, ExternalCSPURI, Size, CreatedAt}` with no members and no recount. Validation:
  - org `ExternalCSPAllowed` (else 40186);
  - `Weighted`, `Anonymous`, `AuthFields`, `TwoFaFields`, `GroupID`, `MemberIDs` all empty (else 400 `ErrInvalidData` "externalCsp excludes …");
  - `1 ≤ Size ≤ ChainMaxCensusSize()` (else 400);
  - `CensusURI` an `https://` URL (else 400).

  Question `Eligibility` on an external census → 400 (`api/processes.go:284` path).
- `api/processes_external_csp.go` (new) — `PUT /processes/{processId}/external-csp`:
  ```go
  func (a *API) setExternalCSPRootsHandler(w http.ResponseWriter, r *http.Request) {
      oid, ok := a.votingProcessID(w, r); if !ok { return }
      // Admin gate as in createProcessCensusCheckoutHandler (processes_census_payment.go:253-266):
      user, ok := apicommon.UserFromContext(r.Context()); if !ok { errors.ErrUnauthorized.Write(w); return }
      vp, questions, err := a.db.ProcessWithQuestions(oid) // db/voting_processes.go:172; ErrNotFound → 404
      if !user.HasRoleFor(vp.OrgAddress, db.AdminRole) {
          errors.ErrUnauthorized.Withf("user is not admin of the organization").Write(w) // 401 40001
          return
      }
      census, err := a.db.Census(vp.CensusID.Hex())
      // !census.ExternalCSP → 409 ErrExternalCSP.Withf("process census is not external")
      // vp.Published || !vp.Publishing.IsZero() → 409 ErrProcessPartiallyPublished
      // decode; len(req.CensusRoots) != len(questions) or any key not a question id → 400
      // each root: externalcsp.ParseRoot; pairwise distinct (map[string]struct{} on hex);
      // not equal to a.csp.PubKey() nor a.csp.BlindPubKey() → 400
      // a.db.SetQuestionsExternalCSPRoots(vp.ID, roots) → 204
  }
  ```
  The handler uses the census checkout handler's Admin check inline, as above; `authorizeStatusChange` (`processes_publish.go:1203`) admits Managers too, so it does not fit here. A non-admin gets 401 `ErrUnauthorized` (40001). The handler doc states that the PUT must precede publish. A PUT racing an in-flight publish is caught by Decidim's `verify_roots!`.

  Roots are decoded as `internal.HexBytes`, which accepts both `"0x02…"` and `"02…"`. The handler doc says so, and a test case sends one root of each form.
- `api/routes.go` + `api/api.go` (protected group `:514-534`): `processesExternalCSPEndpoint = "/processes/{processId}/external-csp"` (PUT).
- `api/apikeys.go`: add `"PUT " + processesExternalCSPEndpoint: ScopeVotingWrite` to `apiKeyAllowlist` (`:51-95`, keyed `"<METHOD> " + pattern`), next to `processesCensusCheckoutEndpoint`. Without it every gem call fails at `api/middlewares.go:232-238` with `ErrAPIKeyNotAllowed`. `api/apikeys_test.go` `TestRequiredScopeForRoute`: add the route → `ScopeVotingWrite`. In `api/processes_external_csp_test.go`, a `vsk_` key with `voting:write` reaches the handler (204 on a valid body, not 403 `ErrAPIKeyNotAllowed`).
- `api/processes_publish.go` `publishPreflightProblems` (`:166-215`), for an external census:
  - a problem per question lacking `ExternalCSPRoot`;
  - a problem if the org lost `ExternalCSPAllowed`;
  - a problem per question with eligibility.
- `api/processes_price.go`: no change. `CensusSize` already reads `census.Size` and the census has no 2FA. Add a test that the quote equals the plain quote at `size`.
- Tests (`api/processes_external_csp_test.go`, template `api/processes_blind_csp_test.go`, helpers `testDB`, `newVotingProcessRequest`, `requestAndParse`):
  - create with `externalCsp` without the org flag → 403 40186; with the flag → census `externalCsp:true`, `size` echoed;
  - each forbidden combination → 400; size 0 or > chain max → 400; eligibility → 400;
  - PUT roots: wrong count, unknown id, invalid point, duplicate, SaaS key → 400; non-admin → 401 40001; non-external → 409; valid → 204 and stored; `0x`-prefixed and bare hex roots both stored as the same bytes;
  - preflight on a draft without roots lists the problem;
  - `TestExternalCSPRootsAPIKey`: the PUT with a `vsk_` `voting:write` key reaches the handler.

Error codes 40185 and 40186 are free on `main` and in #796. Before the PR leaves draft, check the other open saas-backend PRs (`gh pr list --repo vocdoni/saas-backend --state open`, then `rg -n '4018[56]'` on their diffs) and renumber if one claims them.

Commands:
```
go test ./db/ -run 'TestSetCensusExternalCSP|TestSetQuestionsExternalCSPRoots' -count=1   # ok
go test ./api/ -run 'TestExternalCSP|TestRequiredScopeForRoute' -count=1                  # ok
```
Commit: `feat(processes): add external csp census mode with per-question roots on the draft`.

### T4 — S1b: publish with stored roots, 409 guard, resize (saas)

Files:
- `cmd/service/main.go`:
  ```go
  const externalCSPOriginKey = "external_csp_origin" // VOCDONI_EXTERNAL_CSP_ORIGIN
  flag.String(externalCSPOriginKey, "OFF_CHAIN_CA_V2", "census origin of external CSP elections")
  ```
  Parse it with `models.CensusOrigin_value`. It must be `OFF_CHAIN_CA_V2` (only V2 is accepted until V3 origins exist in proto, then `OFF_CHAIN_CA_V3_ECDSA`). `api.Config.ExternalCSPOrigin models.CensusOrigin` → `a.externalCSPOrigin`.
- `api/processes_publish.go`:
  - `startProcessPublish` (`:493-500`): when `census.ExternalCSP`, skip `a.csp.PubKey()`, set `census.Published = db.PublishedCensus{URI: census.ExternalCSPURI, CreatedAt: time.Now()}` and leave `cspPubKey` nil.
  - `assignCensus` (from T1) gains the external branch, which never falls back:
    ```go
    if pw.census.ExternalCSP {
        if len(q.ExternalCSPRoot) == 0 {
            return 0, nil, "", fmt.Errorf("question %s has no external csp root", q.ID.Hex())
        }
        q.CensusOrigin = pw.a.externalCSPOrigin.String()
        q.CensusRoot = q.ExternalCSPRoot
        return pw.a.externalCSPOrigin, q.ExternalCSPRoot, pw.census.ExternalCSPURI, nil
    }
    ```
  - Check that `reloadQuestions`, `reconcileStaleClaim` (`:100-160`) and the checkout webhook (`processes_publish_payment.go:820` → `startProcessPublish`) all reach `assignCensus` with questions loaded from the DB. Grep `rg -n 'Published.Root|csp.PubKey\(\)|BlindPubKey\(\)' api csp` and route every reader of a published root through `questionCensusRoot`.
- `api/processes_admin.go` `questionCensusRoot` (from T1) gains the same no-fallback rule: when `census.ExternalCSP` and the question has neither `CensusRoot` nor `ExternalCSPRoot`, return `fmt.Errorf("question %s has no external csp root", q.ID.Hex())`, never the SaaS key.
- `api/external_csp_guard.go` (new):
  ```go
  // refuseExternalCSP answers 409 on routes that act on census members or sign for the SaaS CSP
  // when the process census is held by an external CSP.
  func (a *API) refuseExternalCSP(next http.HandlerFunc) http.HandlerFunc {
      return func(w http.ResponseWriter, r *http.Request) {
          oid, err := bson.ObjectIDFromHex(chi.URLParam(r, "processId"))
          if err == nil {
              if vp, err := a.db.VotingProcess(oid); err == nil {
                  if c, err := a.db.Census(vp.CensusID.Hex()); err == nil && c.ExternalCSP {
                      errors.ErrExternalCSP.Write(w)
                      return
                  }
              }
          }
          next(w, r) // lookup failures fall through to the handler's own 404/400
      }
  }
  ```
  Wrap these in `api/api.go`:
  - PUT/DELETE `processesCensusEndpoint`, PUT `processesQuestionCensusEndpoint`, GET `processesParticipantsEndpoint`, GET `processesParticipantEndpoint`;
  - the public CSP routes `check`, `auth`, `auth/resend`, `sign`, `sign-batch`, `blind-point`, `blind-sign`, `weight`, `sign-info` (`:575-587`).

  **Not** `census/checkout` (deviation 4).

  Also open on purpose, and named in the guard's doc comment so a reviewer does not read them as gaps:
  - `PUT /processes/{id}` (draft update). It re-resolves the census through `resolveOrCreateDefaultCensus`, so a draft update that carries `externalCsp` goes through T3's validation, and one that drops it replaces the census with a plain one. That is a draft edit by an org admin, and publish preflight then has no external roots to read.
  - `POST /processes/census/validation`. It validates a member census and holds no external-CSP state.
- Defence in depth in `csp/handlers`: at each census load (`auth.go:282`, `processes.go:207,360,968,1040`) add `if census.ExternalCSP { errors.ErrExternalCSP.Write(w); return }` (or return the error where it is not a writer).
- `api/census_propagation.go` and `api/census_guard.go`: add `if census.ExternalCSP { continue }` in the per-process loops. It is a no-op today (no members or group), and it keeps the invariant explicit.
- `POST /processes/{processId}/external-csp/size` in `api/processes_external_csp.go`:
  ```go
  func (a *API) setExternalCSPSizeHandler(w http.ResponseWriter, r *http.Request) {
      // authorizeStatusChange (Manager/Admin); !vp.Published → 409 ErrDuplicateConflict as :617
      // decode ExternalCSPSizeRequest; size > ChainMaxCensusSize() → 400
      growthLock, err := a.censusGrowthLocks.lockOrBusy(r.Context(), vp.OrgAddress) // same lock as members
      defer growthLock.Unlock()
      census := reload; !census.ExternalCSP → 409 ErrExternalCSP
      if req.Size < census.Size → 400 "census size never shrinks"
      if req.Size > census.Size {
          if err := a.censusGrowthPaymentError(censusGrowth{vp: vp, census: census, by: req.Size - census.Size}); err != nil {
              writeSubscriptionError(w, err); return // 402 with quote; pay via POST .../census/checkout
          }
      }
      targets: open questions → censusSizeTarget{question, census, size: uint64(req.Size)}
      // req.Size == census.Size still enqueues: a previous call may have stored the size and then
      // failed (ErrTxQueueFull, a failed job). enqueueSetProcessCensus (processes_admin.go:1093) reads
      // each election's chain size and skips questions already at size, so a retry is a no-op only
      // when the chain has the room.
      jobID, err := a.enqueueSetProcessCensus(vp.OrgAddress, targets)
      if err != nil { writeSubscriptionError(w, err); return } // census.Size untouched; 503 on ErrTxQueueFull
      if req.Size > census.Size { census.Size = req.Size; a.db.SetCensus(census) } // only after the enqueue succeeded
      growthLock.Unlock()
      jobID == "" → 200 {jobId:""} (every open election already has the room); else 202 {jobId}
  }
  ```
  `submitSetProcessCensus` sends the question's own root (T1), equal to the on-chain one, so the DynamicCensus gate is not hit. The growth lock stays held until the size write, so two concurrent resizes cannot both pass the payment check against the old size; `enqueueSetProcessCensus` never waits for the organization lock (it creates the job and resizes in the background), so holding it is cheap. A job that fails after the size write is recovered by the next call with the same size, which re-reads the chain.
- `api/routes.go` + `api/api.go`: `processesExternalCSPSizeEndpoint = "/processes/{processId}/external-csp/size"` (POST, protected group).
- `api/apikeys.go`: add `"POST " + processesExternalCSPSizeEndpoint: ScopeVotingWrite` to `apiKeyAllowlist`; `api/apikeys_test.go` `TestRequiredScopeForRoute` gets the route → `ScopeVotingWrite`.
- Tests (voconed; template `api/processes_blind_csp_test.go`, helpers `enqueueAndPollJob`, `testCastVote(t, vc, signer, processID, proof, pkg)` `api_test.go:867`):
  - `TestExternalCSPPublishKeepsRoots`: two questions, roots from two fresh keys. Publish via the API. Each chain election has `censusRoot` = its root, origin `OFF_CHAIN_CA_V2`, `dynamicCensus` false, `maxCensusSize` = size, `censusURI` = censusUri. Both `CensusOrigin`/`CensusRoot` are stored on the questions.
  - `TestExternalCSPPublishViaReconcile`: simulate the stale-claim path (as `processes_publish_state_test.go` does) → same roots.
  - `TestExternalCSPVote`: sign the 59-byte bundle with the test key (`ethcrypto.Sign(ethereum.Hash(bundle))`, `ProofCA_ECDSA`, `VoteWeight: {1}`) → vote accepted. Signing with the other question's key → rejected.
  - `TestExternalCSPRoutes409`: each wrapped route → 409 40185. `census/checkout` → not 40185.
  - `TestExternalCSPResize`: size+3 → 202. The job completes, chain `maxCensusSize` = new size, `censusRoot` unchanged. The same size again → 200 `{jobId:""}`. Shrink → 400. Unpaid growth on a paid process → 402.
  - `TestExternalCSPResizeRetryAfterQueueFull`: the first call hits `ErrTxQueueFull` (fill the tx queue as the existing queue-full tests do) → 503 and `census.Size` unchanged. A retry with the same size enqueues a job and the chain reaches the size. A job that fails after the size write is recovered the same way: the same size again → 202 and the chain reaches it.
  - `TestExternalCSPResizeAPIKey`: the POST with a `vsk_` `voting:write` key reaches the handler (not 403 `ErrAPIKeyNotAllowed`).
  - `TestExternalCSPNoSaaSFallback`: wipe a question's `externalCspRoot` mid-publish → job fails with "no external csp root" and no tx carries the SaaS key.
  - Propagation: a memberbase change in the org leaves the external census untouched (Size unchanged, no job).

Commands:
```
go test ./api/ -run 'TestExternalCSP|TestRequiredScopeForRoute' -count=1 -v   # PASS for each, ok
go test ./csp/... -count=1                                                    # ok
make test && make lint                              # ok, 0 issues
```
Commits:
- `feat(processes): publish external csp elections with their stored roots`
- `feat(csp): refuse member and signing routes on external csp censuses`
- `feat(processes): resize external csp elections by declared size`

### T5 — G1: crypto, keyring, pin secret (gem)

Branch `feat/external-csp`.

Files:
- `lib/decidim/elections/vocdoni/csp.rb` requires the three below and defines `Csp::Error < StandardError`, `Csp::RootMissing`, `Csp::PinSecretMismatch`, `Csp::TriggerMissing` (raised by T6's check) and `Csp::ConfigurationError < Vocdoni::ConfigurationError` (so `validate_configuration!` callers rescue both). Required from `lib/decidim/elections/vocdoni.rb`, which also requires `securerandom`.
- `lib/decidim/elections/vocdoni/csp/crypto.rb` — the design §4 core, verified, as `module Csp::Crypto` with `module_function`:
  ```ruby
  N = OpenSSL::BN.new("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141", 16).to_i
  GROUP = OpenSSL::PKey::EC::Group.new("secp256k1")
  TAG_ELECTION_ECDSA = "vocdoni/csp/v3/election-ecdsa"

  def keccak(bytes) = OpenSSL::Digest.new("KECCAK-256").digest(bytes)
  def i2b(int) = [int.to_s(16).rjust(64, "0")].pack("H*")
  def b2i(bytes) = bytes.unpack1("H*").to_i(16)

  def hash_to_scalar(tag, data) # first keccak(tag ‖ u32be(i) ‖ data) with 0 < h < n
    256.times do |i|
      h = b2i(keccak(tag.b + [i].pack("N") + data.b))
      return h if h.between?(1, N - 1)
    end
    raise Csp::Error, "no scalar"
  end

  # dE for one on-chain election: root is 32 bytes, seed the 12-byte SaaS question id.
  def election_key(root, seed)
    raise ArgumentError, "root" unless root.bytesize == 32 && b2i(root).between?(1, N - 1)
    raise ArgumentError, "seed" unless seed.bytesize == 12
    hash_to_scalar(TAG_ELECTION_ECDSA, root + seed)
  end

  def public_key(priv) = GROUP.generator.mul(OpenSSL::BN.new(priv)).to_octet_string(:compressed)

  # CAbundle{processId: 1, address: 2, voteWeight: 3} as protobuf, the bytes the chain verifies.
  def ca_bundle(process_id, address, weight = "\x01".b)
    raise ArgumentError unless process_id.bytesize == 32 && address.bytesize == 20 && weight.bytesize.between?(1, 127)
    "\x0a\x20".b + process_id + "\x12\x14".b + address + "\x1a".b + weight.bytesize.chr + weight
  end

  def eth_digest(msg) = keccak("\x19Ethereum Signed Message:\n\#{msg.bytesize}".b + msg)

  def rfc6979_k(priv, digest) # HMAC-SHA256 as libsecp256k1
    x = i2b(priv); v = "\x01".b * 32; k = "\x00".b * 32
    hm = ->(kk, m) { OpenSSL::HMAC.digest("SHA256", kk, m) }
    k = hm.(k, v + "\x00".b + x + digest); v = hm.(k, v)
    k = hm.(k, v + "\x01".b + x + digest); v = hm.(k, v)
    loop do
      v = hm.(k, v); t = b2i(v)
      return t if t.between?(1, N - 1)
      k = hm.(k, v + "\x00".b); v = hm.(k, v)
    end
  end

  # 65-byte r ‖ s ‖ v, low-s, v in {0,1}, equal to go-ethereum crypto.Sign.
  def sign_eth(priv, msg)
    z = eth_digest(msg); k = rfc6979_k(priv, z)
    rp = GROUP.generator.mul(OpenSSL::BN.new(k)).to_octet_string(:uncompressed)
    r = b2i(rp[1, 32]) % N; v = rp[64].ord & 1
    s = blinded_s(k, b2i(z), r, priv)
    raise Csp::Error, "degenerate signature" if r.zero? || s.zero?
    if s > N / 2
      s = N - s
      v ^= 1
    end
    i2b(r) + i2b(s) + v.chr
  end

  # s = k⁻¹(z + r·priv) mod N. Ruby Integer arithmetic runs in variable time and the signer is a
  # network oracle, so the inverse and the products act on k·b and (z + r·priv)·c for fresh random
  # b, c and are unblinded afterwards. The result is the same integer, so RFC 6979 output is unchanged.
  def blinded_s(k, z, r, priv)
    b = SecureRandom.random_number(N - 1) + 1
    c = SecureRandom.random_number(N - 1) + 1
    kinv = ((k * b) % N).pow(N - 2, N) * b % N
    kinv * (((z * c) + (r * ((priv * c) % N))) % N) * c.pow(N - 2, N) % N
  end

  # Compressed public key that produced sig over msg (EIP-191), for specs and self-checks.
  def recover(msg, sig)
    z = b2i(eth_digest(msg)); r = b2i(sig[0, 32]); s = b2i(sig[32, 32]); v = sig[64].ord % 27
    rpt = OpenSSL::PKey::EC::Point.new(GROUP, OpenSSL::BN.new((v.zero? ? "02" : "03") + r.to_s(16).rjust(64, "0"), 16))
    rinv = r.pow(N - 2, N)
    rpt.mul(OpenSSL::BN.new((s * rinv) % N), OpenSSL::BN.new((-z * rinv) % N)).to_octet_string(:compressed)
  end

  def nullifier(address, process_id) = keccak(address + process_id)
  ```
  `sign_eth` asserts `recover(msg, sig) == public_key(priv)` before returning and raises otherwise. That self-check is cheap and catches a broken OpenSSL.
- `lib/decidim/elections/vocdoni/csp/keyring.rb`:
  - `Keyring.load(ENV.fetch("VOCDONI_CSP_ROOTS", ""))` parses `id:hex,id:hex`;
  - each root must be 32 bytes and a valid scalar;
  - `id` must equal `Keyring.id_for(root)` = `keccak(public_key(b2i(root)))[0, 8].unpack1("H*")`, else `ConfigurationError` naming the id only;
  - `#newest_id` is the last entry; `#fetch(id)` raises `RootMissing`; `#ids`;
  - `inspect`/`to_s` are overridden to show ids only.

  `NON_PROD_ROOT_IDS = %w(<dev root id, added during e2e setup>).freeze`. `Keyring#assert_prod_safe!(chain_id)` raises `ConfigurationError` (naming the ids only) when `Vocdoni.lts_chain_id?(chain_id)` and any id is in `NON_PROD_ROOT_IDS`. `chain_id` is the `chainId` of `GET /chain/info` (deviation 7); callers are T8's `record_csp_ids!` and `verify_roots!`.
- `lib/decidim/elections/vocdoni/csp/pin_secret.rb`:
  - `PinSecret.load(ENV["VOCDONI_CSP_PIN_SECRET"])` takes 64 hex chars;
  - `#id` = `keccak(secret)[0, 8]` hex;
  - `#digest(voter_key)` = `OpenSSL::HMAC.hexdigest("SHA256", secret, voter_key)`;
  - `#assert_separate!(keyring)` raises if the secret equals any root;
  - `inspect` shows the id only;
  - `PinSecret.voter_key(election, voter_uid)` (deviation 8):
    ```ruby
    gid = GlobalID.parse(voter_uid) or raise ArgumentError, "voter_uid"
    case gid.model_name
    when "Decidim::Elections::Voter" then "row:\#{election.id}:\#{gid.model_id}"
    when "Decidim::User" then "user:\#{election.id}:\#{gid.model_id}"
    else raise ArgumentError, "voter_uid"
    end
    ```
- `lib/decidim/elections/vocdoni.rb`:
  - add accessors:
    - `chain_api_url`: ENV `VOCDONI_CHAIN_API_URL` with a trailing `/` stripped. Outside production it defaults to `https://api-dev.vocdoni.net/v2`; in production it has no default and a blank value raises `ConfigurationError` (deviation 7);
    - `csp_origin`: ENV `VOCDONI_EXTERNAL_CSP_ORIGIN`, default `OFF_CHAIN_CA_V2`;
    - `census_headroom`: `Rational(ENV.fetch("VOCDONI_CENSUS_HEADROOM", "0.20"))`. A value that does not parse, or falls outside `0 ≤ h ≤ 1`, raises `ConfigurationError` naming the variable. It is a `Rational` so that T8's size arithmetic never touches Float;
  - `Vocdoni.lts_chain_id?(chain_id)` = `chain_id.to_s.start_with?("vocdoni/LTS/")` (deviation 7);
  - `Vocdoni.csp_keyring` / `Vocdoni.csp_pin_secret` are memoized loaders;
  - `Vocdoni.csp_ready!` runs the checks below once per process (memoized on success) and raises `Csp::RootMissing` (code `csp_root_missing`) when roots or the pin secret are absent, or `ConfigurationError` for the rest. T7's sign action and T8's publish job call it first, so a process started without the boot check (console, a Puma without the flag) still refuses to sign or publish half-configured. T6 adds the trigger check, which raises `Csp::TriggerMissing` (code `csp_trigger_missing`).
  - The checks: `OpenSSL::Digest.new("KECCAK-256")` works ("OpenSSL >= 3.2 required" otherwise); the keyring and pin secret load; `assert_separate!`; `census_headroom` parses; in production, `chain_api_url` is set.
- `lib/decidim/elections/vocdoni/engine.rb`: initializer `decidim_elections_vocdoni.csp_boot` (`config.after_initialize`). `after_initialize` also runs for `db:migrate`, `assets:precompile`, `rails runner` and the console, where the first prod deploy has no trigger yet and a build stage has no runtime secrets. So the body runs only when serving:
  ```ruby
  config.after_initialize do
    next unless Decidim::Elections::Vocdoni.csp_boot_check?
    Decidim::Elections::Vocdoni.csp_ready! # raises in production; elsewhere rescued, logged as WARN
  end
  ```
  `csp_boot_check?` = `Rails.const_defined?(:Server) || ENV["VOCDONI_CSP_BOOT_CHECK"] == "1" || (defined?(Sidekiq) && Sidekiq.server?)`. `bundle exec puma` does not define `Rails::Server`, so a deploy that starts Puma directly sets `VOCDONI_CSP_BOOT_CHECK=1` in the web start command. It is never set service-wide (shared environment variables), because the migrate and build steps would see it too (T12). On success it logs `csp_root_id=<newest> pin_secret_id=<id>`. In production a failure raises; elsewhere it logs a warning, and signing then refuses with `csp_root_missing`.
- Specs:
  - `spec/lib/decidim/elections/vocdoni/csp/crypto_spec.rb` (fixtures `spec/fixtures/csp/csp-v3-vectors.json` and `csp-external-v2-ecdsa.json`):
    - `election_key` for seed0 and seed1 equals `electionEcdsaKey.private`/`public`;
    - `ca_bundle(pid, addr, "\x2a")` equals `proofs[0].bundle`, and `sign_eth(dE0, bundle)` equals `proofs[0].signature`;
    - `recover` yields the seed0 root and not seed1's;
    - the V2 fixture: `ca_bundle` (weight 01, 59 bytes) equals `bundle`, `sign_eth` equals `signature`, and `nullifier` equals `nullifier`;
    - low-s holds over 200 random keys/messages (`s <= N/2`, `recover` round-trip);
    - the length prefix is `\n59` (digest equals fixture `digest`);
    - blinding leaves the output byte-identical: `sign_eth(dE0, bundle)` equals `proofs[0].signature` on each of 5 calls (fresh blinding factors each time), and `blinded_s` equals the plain `k.pow(N - 2, N) * (z + r * priv) % N` over 200 random inputs.
  - `keyring_spec.rb`: parse, id mismatch raises without printing the root (`expect { }.to raise_error { |e| expect(e.message).not_to include(root_hex) }`), `newest_id`, `fetch` missing → `RootMissing`, `inspect` hides keys. Prod denylist: `assert_prod_safe!("vocdoni/LTS/1.3")` raises with a denied id; `"vocdoni/DEV/36"` and `"vocdoni/STAGE/12"` do not; an LTS id with only allowed ids does not.
  - `pin_secret_spec.rb`: digest is stable; adding a keyring entry leaves `digest` unchanged (invariant spec 1/2); equal-to-root raises; `voter_key` for both gid kinds and a foreign gid raises. `inspect`, `to_s` and the message of every error `PinSecret.load` and `assert_separate!` raise (bad length, bad hex, equal to a root) never include the secret hex.
  - `spec/lib/decidim/elections/vocdoni/config_spec.rb`:
    - `census_headroom`: unset → `Rational(1, 5)`; `"0"` → 0; `"1"` → 1; `"-0.1"`, `"1.5"` and `"abc"` → `ConfigurationError`;
    - `chain_api_url`: a trailing `/` is stripped; unset in development → the dev URL; unset with `Rails.env` stubbed to production → `ConfigurationError`;
    - `lts_chain_id?`: true for `vocdoni/LTS/1.3`, false for `vocdoni/DEV/36`, `vocdoni/STAGE/12` and nil;
    - boot guard: with `Rails.env` stubbed to production, `Rails::Server` undefined, `VOCDONI_CSP_BOOT_CHECK` unset and no CSP variables, running the `csp_boot` after_initialize block does not raise and does not call `csp_ready!`. With `VOCDONI_CSP_BOOT_CHECK=1` it raises `Csp::RootMissing`;
    - `csp_ready!` with no roots → `Csp::RootMissing`; with valid roots and secret → returns, and a second call does not re-run the checks.

Commands:
```
bundle exec rspec spec/lib/decidim/elections/vocdoni/csp spec/lib/decidim/elections/vocdoni/config_spec.rb   # NN examples, 0 failures
bundle exec rubocop lib/decidim/elections/vocdoni.rb lib/decidim/elections/vocdoni/csp* lib/decidim/elections/vocdoni/engine.rb spec/lib/decidim/elections/vocdoni/csp spec/lib/decidim/elections/vocdoni/config_spec.rb   # no offenses
```
Commits:
- `feat(csp): add per-election key derivation and eth signing in stdlib ruby`
- `feat(csp): add root keyring and pin secret with boot checks`

### T6 — G2: schema (gem)

Files:
- `db/migrate/20261116100001_add_csp_to_vocdoni_processes.rb`: `add_column :decidim_vocdoni_processes, :csp_root_id, :string`, `:pin_secret_id, :string`, `:csp_state, :string`, `:csp_verified_at, :datetime`. The declared size reuses the existing `census_size`.
- `db/migrate/20261116100002_create_decidim_vocdoni_csp_elections.rb`:
  ```ruby
  create_table :decidim_vocdoni_csp_elections do |t|
    t.references :process, null: false, foreign_key: { to_table: :decidim_vocdoni_processes, on_delete: :restrict }
    t.bigint :decidim_question_id, null: false, index: { unique: true }
    t.string :seed, null: false, index: { unique: true }          # 24 hex, SaaS question ObjectID
    t.string :census_root, null: false                            # 66 hex, public
    t.string :upstream_id, index: { unique: true, where: "upstream_id IS NOT NULL" }
    t.timestamps
  end
  ```
- `db/migrate/20261116100003_create_decidim_vocdoni_csp_pins.rb`:
  ```ruby
  create_table :decidim_vocdoni_csp_pins do |t|
    t.references :process, null: false, foreign_key: { to_table: :decidim_vocdoni_processes, on_delete: :restrict }
    t.bigint :decidim_question_id, null: false
    t.bigint :election_id, null: false
    t.string :csp_root_id, null: false
    t.string :seed, null: false
    t.string :voter_digest, null: false
    t.string :address
    t.string :nullifier
    t.datetime :vote_confirmed_at
    t.datetime :purged_at
    t.timestamps
  end
  add_index :decidim_vocdoni_csp_pins, [:decidim_question_id, :voter_digest], unique: true, name: "index_vocdoni_csp_pins_on_question_and_digest"
  add_index :decidim_vocdoni_csp_pins, [:decidim_question_id, :address], unique: true, where: "address IS NOT NULL", name: "index_vocdoni_csp_pins_on_question_and_address"
  execute <<~SQL
    CREATE FUNCTION decidim_vocdoni_csp_pins_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'csp pins are never deleted'; END IF;
      IF NEW.process_id IS DISTINCT FROM OLD.process_id
         OR NEW.decidim_question_id IS DISTINCT FROM OLD.decidim_question_id
         OR NEW.election_id IS DISTINCT FROM OLD.election_id
         OR NEW.csp_root_id IS DISTINCT FROM OLD.csp_root_id
         OR NEW.seed IS DISTINCT FROM OLD.seed
         OR NEW.voter_digest IS DISTINCT FROM OLD.voter_digest THEN
        RAISE EXCEPTION 'csp pin identity is immutable';
      END IF;
      IF NEW.address IS DISTINCT FROM OLD.address AND NEW.address IS NOT NULL THEN
        RAISE EXCEPTION 'csp pin address can only be purged';
      END IF;
      IF NEW.nullifier IS DISTINCT FROM OLD.nullifier AND NEW.nullifier IS NOT NULL THEN
        RAISE EXCEPTION 'csp pin nullifier can only be purged';
      END IF;
      IF OLD.vote_confirmed_at IS NOT NULL AND NEW.vote_confirmed_at IS DISTINCT FROM OLD.vote_confirmed_at THEN
        RAISE EXCEPTION 'csp pin confirmation is final';
      END IF;
      RETURN NEW;
    END $$ LANGUAGE plpgsql;
    CREATE TRIGGER decidim_vocdoni_csp_pins_guard BEFORE UPDATE OR DELETE ON decidim_vocdoni_csp_pins
      FOR EACH ROW EXECUTE FUNCTION decidim_vocdoni_csp_pins_guard();

    -- Row triggers do not fire on TRUNCATE.
    CREATE FUNCTION decidim_vocdoni_csp_pins_no_truncate() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'csp pins are never deleted';
    END $$ LANGUAGE plpgsql;
    CREATE TRIGGER decidim_vocdoni_csp_pins_no_truncate BEFORE TRUNCATE ON decidim_vocdoni_csp_pins
      FOR EACH STATEMENT EXECUTE FUNCTION decidim_vocdoni_csp_pins_no_truncate();
  SQL
  ```
  `down` raises `ActiveRecord::IrreversibleMigration`, because pins are evidence.
- Models:
  - `app/models/decidim/elections/vocdoni/csp_election.rb`: `belongs_to :process`, validations, `seed_bytes` = `[seed].pack("H*")`.
  - `app/models/decidim/elections/vocdoni/csp_pin.rb`: `belongs_to :process`; scopes `confirmed`, `unconfirmed`, `live` (address not null); `readonly?` false, but `before_destroy { throw :abort }`.
  - `Process`:
    ```ruby
    has_many :csp_elections, dependent: :delete_all
    has_many :csp_pins, dependent: :restrict_with_exception
    ```
    `csp_elections` hold only public data (seed, census root, upstream id) and exist from the draft on, so they go with the process; `before_destroy :delete_upstream_draft` can then still delete a failed draft. Pins are evidence, so a process with pins cannot be destroyed (the FK `on_delete: :restrict` and the trigger agree). `CSP_STATES = [nil, "verified", "compromised"]`; `csp_verified?`. `STATES` is untouched (deviation 2).
- `Vocdoni.csp_ready!` (T5) gains the trigger check: raise `Csp::TriggerMissing` (`csp_trigger_missing`) unless `pg_trigger` has both `decidim_vocdoni_csp_pins_guard` and `decidim_vocdoni_csp_pins_no_truncate`. That catches a DB loaded from `schema.rb`, which drops triggers. It runs only through the serving-only boot guard and the lazy sign/publish check (T5), so `db:migrate`, which creates the trigger, runs on a DB that does not have it yet.
- Specs `spec/models/decidim/elections/vocdoni/csp_pin_spec.rb`:
  - duplicate (question, digest) → `RecordNotUnique`; duplicate (question, address) → `RecordNotUnique`; two NULL addresses are fine;
  - every expectation that the trigger raises runs inside `ActiveRecord::Base.transaction(requires_new: true) { … }`, so the failed statement rolls back to a savepoint and later statements in the example do not hit `PG::InFailedSqlTransaction`;
  - `delete_all` → `ActiveRecord::StatementInvalid /never deleted/`; `TRUNCATE decidim_vocdoni_csp_pins` → `/never deleted/`; changing the address to another value → raises; to nil → ok; changing the digest → raises; re-setting `vote_confirmed_at` → raises;
  - both triggers exist in the test DB (`pg_trigger` count 2). If `rake test_app` loaded from `schema.rb`, this fails: then add `config.active_record.schema_format = :sql` to the generated test app via `spec/decidim_dummy_app` setup, as documented in the PR;
  - `csp_ready!` raises `Csp::TriggerMissing` after `DROP TRIGGER` inside a `requires_new` transaction that the example rolls back;
  - `Process#destroy` with csp_elections and no pins succeeds; with a pin it raises `ActiveRecord::DeleteRestrictionError`.

Commands:
```
bundle exec rake test_app        # if not yet generated for this clone
cd spec/decidim_dummy_app && bin/rails decidim_elections_vocdoni:install:migrations && bin/rails db:migrate RAILS_ENV=test && cd ../..
bundle exec rspec spec/models/decidim/elections/vocdoni   # 0 failures
bundle exec rubocop db app/models spec/models   # no offenses
```
Commit: `feat(csp): add csp elections and append-only pins tables`.

### T7 — G2: VoterCspController, ChainClient, ResizeCensusJob skeleton (gem)

Files:
- `lib/decidim/elections/vocdoni/engine.rb`: initializer `decidim_elections_vocdoni.csp_routes`:
  ```ruby
  Decidim::Elections::Engine.routes.append do
    resources :elections, only: [] do
      get "csp/status", to: "/decidim/elections/vocdoni/voter_csp#status", as: :csp_status
      post "csp/sign", to: "/decidim/elections/vocdoni/voter_csp#sign", as: :csp_sign
      post "csp/confirm", to: "/decidim/elections/vocdoni/voter_csp#confirm", as: :csp_confirm
    end
  end
  ```
  Also: `Rack::Attack.throttle("vocdoni/csp/ip", limit: 120, period: 60) { |req| req.ip if req.path.include?("/csp/") } if defined?(Rack::Attack)`.
- `lib/decidim/elections/vocdoni/engine.rb`: initializer `decidim_elections_vocdoni.csp_filter_parameters`: `Rails.application.config.filter_parameters += [:address, :nullifier, :pinnedAddress]`. Rails logs `Parameters: {"address"=>…}` at info for every sign POST, and the gem must never log an address. Rails matches these filters as substrings, so host keys such as `email_address` are filtered in the logs too; that only affects log output.
- `app/services/decidim/elections/vocdoni/chain_client.rb` (new, next to `api_client.rb`). Faraday on `Vocdoni.chain_api_url`:
  - `chain_info` (`GET /chain/info`; its `chainId` is the value deviation 7 keys on);
  - `election(id)` (`GET /elections/{id}`);
  - `vote(nullifier)` (`GET /votes/{nullifier}`, `nil` on 404).

  Timeouts are 5 s; errors raise `ApiError(transient: true)`. T7's `confirm` and `status_for`, and T8's jobs, use it.
- `app/jobs/decidim/elections/vocdoni/resize_census_job.rb` (new): `class ResizeCensusJob < ApplicationJob; queue_as :vocdoni; def perform(process_id); end; end`. T7 only enqueues it; T8 writes the body.
- `app/controllers/decidim/elections/vocdoni/voter_csp_controller.rb`, nested as `module Decidim; module Elections; module Vocdoni; class VoterCspController`, so that `Process` resolves to `Vocdoni::Process` and not `::Process`:
  ```ruby
  class VoterCspController < Decidim::Elections::ApplicationController
    include Decidim::Elections::UsesCensusAccess
    protect_from_forgery with: :exception   # the booth sends X-CSRF-Token from the meta tag

    rescue_from Csp::PinSecretMismatch do |e| csp_failure("pin_secret_mismatch", e) end
    rescue_from Csp::RootMissing do |e| csp_failure("csp_root_missing", e) end
    rescue_from Csp::TriggerMissing do |e| csp_failure("csp_trigger_missing", e) end

    def status
      return render_error(:forbidden, "not_in_census") if voter_uid.blank?
      return render_error(:too_many_requests, "rate_limited") unless throttle?("status", nil, 30)
      render json: { questions: process.csp_elections.map { |ce| status_for(ce) } }
    end

    def sign
      Vocdoni.csp_ready! # roots, pin secret, trigger (T5/T6); raises before any digest is computed
      return render_error(:forbidden, "not_allowed") unless allowed_to?(:create, :vote, election:)
      return render_error(:forbidden, "not_in_census") if voter_uid.blank?
      ce = signable_csp_election(params.require(:questionId)) or return render_error(:conflict, "question_closed")
      address = parse_address(params.require(:address)) or return render_error(:unprocessable_entity, "invalid_address")
      return render_error(:too_many_requests, "rate_limited") unless throttle?("sign", ce.decidim_question_id, 3)
      root = signing_root! # pin_secret_mismatch / csp_root_missing → 500 + alert log
      pin = CspPin.find_by(decidim_question_id: ce.decidim_question_id, voter_digest: digest)
      return answer_pin(pin, address, ce, root) if pin

      created = nil
      CspPin.transaction do
        Process.lock.find(process.id) # serialises new pins and the roster check per process
        enqueue_resize_if_grown
        begin
          CspPin.transaction(requires_new: true) do
            created = CspPin.create!(process:, decidim_question_id: ce.decidim_question_id, election_id: election.id,
                                     csp_root_id: process.csp_root_id, seed: ce.seed, voter_digest: digest,
                                     address: address.unpack1("H*"),
                                     nullifier: Csp::Crypto.nullifier(address, [ce.upstream_id].pack("H*")).unpack1("H*"))
          end
        rescue ActiveRecord::RecordNotUnique
          created = nil
        end
      end
      return answer_signature(ce, address, root, "issued") if created # after commit

      pin = CspPin.find_by(decidim_question_id: ce.decidim_question_id, voter_digest: digest)
      return answer_pin(pin, address, ce, root) if pin
      log_sign(ce, "address_taken")
      render_error(:conflict, "address_taken")
    end

    def confirm
      # pin for (question, digest) with an address; GET chain /votes/{nullifier} via ChainClient;
      # 200 → update!(vote_confirmed_at: Time.current) unless already set; render status_for
    end

    private

    def render_error(status, code) = render(json: { error: code }, status:)

    # 500 + an error-level log with the process id and csp_root_id, never key material.
    def csp_failure(code, error)
      Rails.logger.error({ event: "csp.failure", code:, process_id: process&.id, csp_root_id: process&.csp_root_id,
                           error: error.class.name }.to_json)
      render_error(:internal_server_error, code)
    end

    def answer_pin(pin, address, ce, root)
      if pin.address.nil? || pin.address != address.unpack1("H*")
        log_sign(ce, "address_pinned")
        return render_error(:conflict, "address_pinned")
      end
      answer_signature(ce, address, root, "resigned")
    end

    def answer_signature(ce, address, root, outcome)
      d = Csp::Crypto.election_key(root, ce.seed_bytes)
      raise Csp::Error, "root mismatch" unless Csp::Crypto.public_key(d).unpack1("H*") == ce.census_root
      bundle = Csp::Crypto.ca_bundle([ce.upstream_id].pack("H*"), address)
      sig = Csp::Crypto.sign_eth(d, bundle)
      log_sign(ce, outcome)
      render json: { signature: sig.unpack1("H*"), weight: "01", proofType: "ECDSA" }
    end

    def signable_csp_election(question_id)
      return nil unless process.csp_verified? && election.ongoing?
      ce = process.csp_elections.find_by(decidim_question_id: question_id.to_i) or return nil
      question = election.questions.find_by(id: ce.decidim_question_id) or return nil
      meta = process.questions_metadata.find { |m| m["decidim_question_id"].to_i == question.id }
      return nil unless meta && meta["vocdoni_status"].to_s.upcase == "READY" && ce.upstream_id.present?
      return nil if election.per_question? && !question.voting_enabled?
      ce
    end

    # A missing pin secret raises RootMissing (csp_root_missing), not NoMethodError on nil.
    def digest = @digest ||= (Vocdoni.csp_pin_secret or raise Csp::RootMissing).digest(Csp::PinSecret.voter_key(election, voter_uid))
    def process = @process ||= election.vocdoni_process
    def parse_address(hex) = hex.to_s.match?(/\A0x\h{40}\z/) ? [hex[2..].downcase].pack("H*") : nil

    def signing_root!
      raise Csp::PinSecretMismatch unless process.pin_secret_id == Vocdoni.csp_pin_secret.id
      Vocdoni.csp_keyring.fetch(process.csp_root_id) # RootMissing
    end

    def enqueue_resize_if_grown
      roster = election.census.count(election) # deviation 11
      return if roster <= process.census_size.to_i
      return unless Rails.cache.write("vocdoni/csp/resize/\#{process.id}", 1, expires_in: 1.minute, unless_exist: true)
      ResizeCensusJob.perform_later(process.id)
    end

    def throttle?(kind, question_id, limit) # per (digest, question), Rails.cache counter, 60 s window
      key = "vocdoni/csp/\#{kind}/\#{digest}/\#{question_id}"
      n = Rails.cache.increment(key, 1, expires_in: 1.minute) || (Rails.cache.write(key, 1, expires_in: 1.minute) && 1)
      n <= limit
    end

    def log_sign(ce, outcome) # never address or nullifier
      Rails.logger.info({ event: "csp.sign", process_id: process.id, question_id: ce.decidim_question_id,
                          voter_digest: digest[0, 16], outcome: }.to_json)
    end
  end
  ```
  `status_for(ce)` returns `{questionId, votingEnabled, canVote, pinnedAddress, nullifier, hasVoted}`. `hasVoted` = `vote_confirmed_at.present?`. It lazily re-checks unconfirmed pins with a live address through ChainClient, at most once per 30 s per pin (cache). `status` also computes `digest`, so it rescues a missing pin secret the same way (`csp_root_missing`).
- Specs `spec/controllers/decidim/elections/vocdoni/voter_csp_controller_spec.rb` (template fork `spec/controllers/decidim/elections/booth_spec.rb`; factories `:election` traits `:published :ongoing :per_question :with_internal_users_census :with_token_csv_census`, `:election_question :voting_enabled`, `:election_voter`, gem `:vocdoni_process`). Use a test root and pin secret via `stub_const`/ENV in `before`.
  - Sign returns a signature that `Crypto.recover`s to `ce.census_root` over `ca_bundle(upstream, address)`.
  - Same address twice → the same signature (RFC 6979), one pin.
  - Different address → 409 `address_pinned`.
  - Another voter, same address → 409 `address_taken`.
  - Purged pin (address nil) → 409 `address_pinned`.
  - `csp_state` nil or compromised → 409 `question_closed`. Status not READY → 409. Per-question not enabled → 409.
  - Voter not in census → 403. Missing CSRF token (`ActionController::Base.allow_forgery_protection = true` in the example) → 422/InvalidAuthenticityToken.
  - `pin_secret_id` differs → 500 `pin_secret_mismatch`. Unknown `csp_root_id` → 500 `csp_root_missing`, no fallback. No pin secret configured → 500 `csp_root_missing` on both sign and status (not a NoMethodError).
  - Adding a second keyring root (newest changes) → same digest, still `address_pinned`, still signs with the recorded root (invariant spec).
  - Roster (`election.census.count(election)`) above `census_size` → `ResizeCensusJob` enqueued once.
  - Concurrency: two threads, same voter, different addresses → exactly one pin, and the other gets 409. Use `ActiveRecord::Base.connection_pool.with_connection` and turn transactional fixtures off for this example. Its pins cannot be deleted by the usual cleanup, so the example's `after` runs `ALTER TABLE decidim_vocdoni_csp_pins DISABLE TRIGGER USER; DELETE FROM decidim_vocdoni_csp_pins; ALTER TABLE decidim_vocdoni_csp_pins ENABLE TRIGGER USER` and then deletes the rows it created in the other tables.
  - Fourth sign in a minute → 429. The test env cache is `:null_store`, so this example sets `allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)`.
  - Log lines contain neither the address nor the nullifier (capture `Rails.logger`).
  - Request log: with `Rails.logger` captured at info, a sign request's output does not include the address hex (the `Parameters:` line shows `[FILTERED]`).
  - `spec/services/decidim/elections/vocdoni/chain_client_spec.rb` (WebMock): `chain_info`, `election`, `vote` 200 and 404 → nil, timeout → transient `ApiError`, and a trailing `/` on the base URL does not produce `//`.

Commands:
```
bundle exec rspec spec/controllers/decidim/elections/vocdoni/voter_csp_controller_spec.rb spec/services/decidim/elections/vocdoni/chain_client_spec.rb   # 0 failures
bundle exec rubocop app/controllers app/services/decidim/elections/vocdoni/chain_client.rb app/jobs/decidim/elections/vocdoni/resize_census_job.rb lib/decidim/elections/vocdoni/engine.rb spec/controllers spec/services   # no offenses
```
Commit: `feat(csp): add voter sign, status and confirm endpoints with address pinning`.

### T8 — G3: publish job, verify_roots!, resize job, sync (gem)

Files:
- `app/services/decidim/elections/vocdoni/api_client/elections.rb`: add
  - `set_external_csp_roots(process_id, roots)` → `PUT /processes/{id}/external-csp {censusRoots}`;
  - `external_csp_size(process_id, size)` → `POST /processes/{id}/external-csp/size {size}`, which returns `{jobId}` (202, or 200 with `jobId: ""` when every open election already has the room);
  - `census_checkout(process_id, census_size:, return_url:)` → `POST /processes/{id}/census/checkout {censusSize, returnURL}`. The response is `ProcessCheckoutResponse{clientSecret, sessionId, amountCents, currency}` (saas `api/apicommon/voting_processes.go:216`), with no URL.
- `lib/decidim/elections/vocdoni.rb`: `Vocdoni.declared_census_size(election, roster)` (deviation 10):
  ```ruby
  # maxCensusSize declared for a roster: token_csv censuses are frozen after publish, so they keep
  # the exact row count; internal_users get the configured headroom. Rational, never Float.
  def declared_census_size(election, roster)
    return roster if election.census_manifest.to_s == "token_csv"
    (roster * (1 + census_headroom)).ceil
  end
  ```
  The roster is always `election.census.count(election)` (deviation 11).
- `app/services/decidim/elections/vocdoni/csp_verifier.rb` (new): `CspVerifier.new(process, chain: ChainClient.new)` with `verify_roots!` and `recheck!`. The publish job, the sync job and the admin "Verify roots" action (T9, through `SyncProcessJob`) share it.
  ```ruby
  def verify_roots!
    info = chain.chain_info
    raise_compromised!("chain_id") if process.chain_id.present? && info["chainId"] != process.chain_id
    begin
      Vocdoni.csp_keyring.assert_prod_safe!(info["chainId"]) # deviation 7
    rescue Csp::ConfigurationError
      raise_compromised!("root_denied")
    end
    process.csp_elections.each do |ce|
      e = chain.election(ce.upstream_id)
      checks = immutable_checks(ce, e).merge(
        anonymous: e.dig("voteMode", "anonymous") == false,
        org: e["organizationId"].to_s.delete_prefix("0x").casecmp?(Vocdoni.org_address.delete_prefix("0x"))
      )
      raise_compromised!(checks.reject { |_, ok| ok }.keys.join(",")) unless checks.values.all?
      check_size(e)
    end
    process.update!(csp_state: "verified", csp_verified_at: Time.current)
  end

  # Runs on every sync tick of a verified process. Only what the chain makes immutable can flag it.
  def recheck!
    process.csp_elections.each do |ce|
      e = chain.election(ce.upstream_id)
      failed = immutable_checks(ce, e).reject { |_, ok| ok }.keys
      raise_compromised!(failed.join(",")) if failed.any?
      check_size(e)
    end
  end

  private

  def immutable_checks(ce, e)
    { root: e.dig("census", "censusRoot").to_s.delete_prefix("0x").downcase == ce.census_root,
      origin: e.dig("census", "censusOrigin") == Vocdoni.csp_origin,
      dynamic: e.dig("electionMode", "dynamicCensus") == false }
  end

  # A chain size below census_size means a resize has not mined yet; it is never a compromise (deviation 12).
  def check_size(e)
    chain_size = e.dig("census", "maxCensusSize").to_i
    return if chain_size >= process.census_size.to_i
    Rails.logger.warn({ event: "csp.size_behind", process_id: process.id, chain_size:, census_size: process.census_size }.to_json)
    return unless Rails.cache.write("vocdoni/csp/resize/\#{process.id}", 1, expires_in: 1.minute, unless_exist: true)
    ResizeCensusJob.perform_later(process.id)
  end
  ```
  `raise_compromised!` sets `csp_state: "compromised"`, writes `last_error` (`record_failure!`) naming the failed checks, and raises a non-transient error. The admin dashboard shows "end this election". `ChainClient` errors are transient `ApiError`s: `verify_roots!` lets them propagate without touching `csp_state`, so it stays nil and the next sync tick retries.
- `publish_election_job.rb`:
  - First call in `perform` after `bootstrap!`: `Vocdoni.csp_ready!` (T5/T6 lazy check). `record_step_failure!` records a failure before any SaaS call.
  - Replace `prepare_census!` with `declare_census!`: `@roster = election.census.count(election)`; raise non-transient `ApiError("empty census")` if 0; `process.update!(census_size: Vocdoni.declared_census_size(election, @roster))` if blank.
  - `census_payload` → `{ "externalCsp" => { "size" => process.census_size, "censusUri" => election_url } }`, where `election_url` = `Decidim::ResourceLocatorPresenter.new(election).url`. It carries no `authFields`, `twoFaFields` or `groupId` (T3 answers 400 to them); `auth_fields`, `two_fa_fields` and the member/group helpers go.
  - `question_payload` adds `"metadata" => { "decidimQuestionId" => question.id.to_s }`.
  - Before create, `record_csp_ids!`:
    - raise `Csp::RootMissing` when `Vocdoni.csp_keyring` is nil or has no ids (never publish without a root);
    - `Vocdoni.csp_keyring.assert_prod_safe!(chain.chain_info["chainId"])` (deviation 7): a denied id raises `ConfigurationError` and nothing is created;
    - `process.update!(csp_root_id: keyring.newest_id, pin_secret_id: pin_secret.id)` only when blank. They are never rewritten.
  - After `ensure_process_created!`, `ensure_csp_elections!`:
    - read `remote_process["questions"]` and map by `q.dig("metadata", "decidimQuestionId")`; raise if any Decidim question is unmapped;
    - the seed is the remote question id and must match `/\A\h{24}\z/` (a Mongo ObjectID), else raise non-transient;
    - per question, `CspElection.find_or_create_by!(process:, decidim_question_id:)` with `seed: remote id`;
    - if a row exists with a different seed → raise (never re-key);
    - `census_root = Crypto.public_key(Crypto.election_key(root, seed_bytes))` hex;
    - unless the remote is live, call `client.elections.set_external_csp_roots(id, rows.to_h { [seed, "0x"+census_root] })`.
  - `persist_process_metadata!` and `remote_question_for` map by `decidimQuestionId` and set `CspElection#upstream_id`:
    - normalised as `upstream.to_s.delete_prefix("0x").downcase`, which must match `/\A\h{64}\z/`, else raise non-transient;
    - write-once: a row whose `upstream_id` is set and differs raises and is never overwritten (`CspElection` validates this too);
    - for external-CSP processes it keeps `process.census_size` and does not copy `remote_census_size` (deviation 12).
  - After `published`, `CspVerifier.new(process).verify_roots!`.
- `app/jobs/decidim/elections/vocdoni/resize_census_job.rb` (the body; T7 created the class):
  ```ruby
  retry_on ApiError, wait: :polynomially_longer, attempts: 5 do |job, error|
    Process.find_by(id: job.arguments.first)&.record_failure!("census resize failed: \#{error.message}", step: "resize")
  end

  def perform(process_id)
    @process = Process.find_by(id: process_id) or return
    @election = process.election
    roster = election.census.count(election)
    target = roster > process.census_size.to_i ? Vocdoni.declared_census_size(election, roster) : process.census_size.to_i
    return confirm_on_chain!(target) if chain_size >= target # nothing to send; record what the chain has
    response = request_size!(target)
    await_job!(response["jobId"]) # ApplicationJob: raises on a failed or timed-out SaaS job; a blank id is a no-op
    confirm_on_chain!(target)
  end
  ```
  - `chain_size` is the smallest `maxCensusSize` over the process's `csp_elections` whose chain status is open, read through `ChainClient`.
  - `confirm_on_chain!(target)` re-reads `chain_size`. When it is `>= target`, `process.update!(census_size: chain_size)`. Otherwise it raises a transient `ApiError("resize not on chain yet")`, so `retry_on` re-enqueues with backoff. After the last attempt it writes `last_error`, and the next sign or sync tick enqueues the job again.
  - `census_size` changes only here and at publish. It never shrinks, because `target >= census_size` and the chain accepts increases only.
  - `request_size!(target)` calls `external_csp_size(id, target)`. On a 402 `ApiError` it calls `census_checkout(id, census_size: target, return_url: admin_url)`, where `admin_url` is the election's admin dashboard URL:
    - 200 (the managed Decidim org's integrator wallet was debited): retry `external_csp_size` once;
    - `ApiError` code 40175 (`ErrInsufficientWalletBalance`): `record_failure!("integrator wallet short", step: "resize")`, leave `census_size` unchanged and return without retrying;
    - a 200 carrying a `sessionId` means the org is not managed and a Stripe session the gem cannot complete was opened: `record_failure!("census growth needs payment", step: "resize")`, without retrying.
  - Idempotent. T7's sign path, `CspVerifier#check_size` and the admin "sync census size" button (T9) enqueue it.
- `sync_process_job.rb`:
  - `extract_questions_meta` maps by `metadata.decidimQuestionId` (deviation 2);
  - `persist!`: when `process.csp_elections.exists?`, `census_size` is not taken from the SaaS (`remote.dig("census", "size")`). It is the size Decidim confirmed on chain, and the SaaS stores the requested size before the resize mines (deviation 12);
  - `derive_state` is untouched;
  - when the remote is published, the process has `csp_elections` and `csp_state.nil?`: `CspVerifier#verify_roots!`. Transient chain errors are logged at WARN and not recorded as a step failure; the next tick retries;
  - when `csp_state == "verified"`: `CspVerifier#recheck!`. A root, origin or `dynamicCensus` mismatch → `compromised`. A chain size below `census_size` → WARN and `ResizeCensusJob`, never `compromised`.
- Specs (WebMock):
  - `declared_census_size` (in `spec/lib/decidim/elections/vocdoni/config_spec.rb`): roster 5 → 6; roster 10 → 12; roster 1 → 2; `token_csv` 5 → 5; `VOCDONI_CENSUS_HEADROOM=0` → roster;
  - publish job: the payload has `externalCsp` with `size` = `declared_census_size(roster)` and `metadata.decidimQuestionId`, and no `authFields`, `twoFaFields` or `groupId`; there is no `/members` or `/groups` call; roots PUT equals the derived roots of the returned seeds; reverse question order in the response still maps correctly;
  - publish job refusals: an empty keyring → `csp_root_missing` and no `POST /processes`; a `vocdoni/LTS/1.3` chain id with a denied root id → no `POST /processes`; a 23-hex seed → raise; an upstream id with `0x` and upper case is stored as 64 lower-case hex; a second, different upstream id → raise;
  - `verify_roots!` → verified. Each failing check (root, origin, dynamic, anonymous, org, chain_id, root_denied) → compromised and no sign (controller spec hook). A chain size below `census_size` → still verified, WARN logged, `ResizeCensusJob` enqueued;
  - recovery: chain 503 in `verify_roots!` at publish → `csp_state` nil; a later `SyncProcessJob` tick with the chain back → verified;
  - resize job:
    - roster within `census_size` and chain at size → no SaaS call;
    - the roster grows past `census_size` → POST size = `declared_census_size(new roster)` → 202 → awaits the job → reads the chain → `census_size` = chain size;
    - 200 `{jobId:""}` → confirms on chain without awaiting;
    - SaaS job failed → `last_error` after the last retry, `census_size` unchanged;
    - chain still below the target after the job → transient retry;
    - 402 → `census_checkout(censusSize: target, returnURL:)` → 200 → retry → success;
    - 402 → checkout → 40175 → `last_error` "integrator wallet short", `census_size` unchanged;
  - sync job:
    - maps by id and flags a changed root;
    - a sync during an in-flight resize (SaaS `census.size` > chain `maxCensusSize` >= `census_size`) leaves `csp_state` verified and `census_size` unchanged;
    - a SaaS `census.size` never overwrites `census_size` on an external-CSP process.

Commands:
```
bundle exec rspec spec/jobs spec/services/decidim/elections/vocdoni/csp_verifier_spec.rb spec/lib/decidim/elections/vocdoni/config_spec.rb   # 0 failures
bundle exec rubocop app/jobs app/services lib spec/jobs spec/services spec/lib   # no offenses
```
Commits:
- `feat(publish): publish elections with external csp roots and verify them on chain`
- `feat(csp): resize the declared census as the roster grows`

### T9 — G3: manifest, per-question end, purge, admin count (gem)

Files:
- `voting_backend.rb`:
  - `supports_per_question = true`; drop `pre_ballot_partial`;
  - `voted { |election, voter_uid| … }`: true when every `election.available_questions` has a `CspPin.confirmed` for `(question, digest(voter_key(election, voter_uid)))`. It starts with `return false if voter_uid.blank? || questions.empty? || Vocdoni.csp_pin_secret.nil?`: the fork's `available_questions` (`election.rb:139-143`) is empty for a per_question election with no question enabled and after all results are published, where `all?` would be vacuously true, and the election page renders this, so a missing pin secret must not raise there;
  - `booth_config` drops `credentials`/`contact` and adds `signUrl`, `statusUrl`, `confirmUrl` (from `Decidim::EngineRouter.main_proxy(election.component).election_csp_sign_path(election)`, and so on), `proofType: "ECDSA"`, `perQuestion: election.per_question?`;
  - the `i18n` slice drops `:otp`;
  - `csp_directives` adds nothing new (CSP calls are same-origin).
- `engine.rb` subscriber on `decidim.elections.admin.update_question_status:after`: when `action == :publish_results` (or the equivalent string) and the election is Vocdoni-backed, enqueue `EndQuestionOnChainJob(question.id)` → `bulk_set_question_status(process_id, status: "ENDED", question_ids: [vocdoni_question_id])`, then `SyncElectionResultsJob`. `enable_voting` needs no hook.
- `app/jobs/.../purge_csp_pins_job.rb`:
  - on schedule, scheduled by `SyncElectionResultsJob` when results are published: `perform_later(process.id)` with `wait: 30.days`;
  - `CspPin.where(process:).where.not(address: nil).update_all(address: nil, nullifier: nil, purged_at: Time.current)`; the trigger allows this.
- Admin dashboard partial (`app/views/decidim/elections/vocdoni/admin/dashboard/_security.html.erb`): per question, root, `maxCensusSize`, signatures issued (`CspPin.where(decidim_question_id:).count`), confirmed votes, `csp_state`, and two buttons:
  - "Sync census size" enqueues `ResizeCensusJob`;
  - "Verify roots", shown while the process is published and `csp_state` is nil, enqueues `SyncProcessJob`, which runs `verify_roots!` in that state (T8).

  Both are POST actions on `Admin::SecurityController` (`sync_census_size`, `verify_roots`, behind the same permission as `update`). They only enqueue, because controllers never call the APIs (gem ARCHITECTURE §0.5).
- Security tab, 2FA options. Every Vocdoni-backed election publishes with the external CSP (T8), the SaaS refuses its auth steps with 409, and OTP is a follow-up (design §11.1). So `admin/security/_two_factor.html.erb` renders the email/SMS checkboxes disabled, with the note "One-time codes for voters are not available yet; they will be added in a later release." (new key `decidim.elections.vocdoni.admin.security.show.two_factor.unavailable` in en/ca/es). The fieldset gets `data-security-locked`, and `security.js` leaves a locked fieldset disabled when the admin switches to the secret vote. `UpdateElectionSecurity` stores `twofa_fields: []` whatever is submitted, and the dashboard summary lists no code channel. T8 drops `authFields`/`twoFaFields` from the census payload.
- Remove `app/views/decidim/elections/vocdoni/booth/_otp_panel*` and its i18n keys (`i18n-tasks unused` clean).
- Specs:
  - manifest `voted`: true/false; false with no available questions; false (no error) with no pin secret;
  - `booth_config` keys (no credentials or contact);
  - subscriber enqueues end only for `publish_results`;
  - purge job clears addresses and keeps the digest/confirmed counts;
  - `spec/requests/decidim/elections/vocdoni/admin/security_spec.rb`: the 2FA checkboxes render disabled with the note; a PUT with `email=1` stores no `twofa_fields`. `spec/requests/decidim/elections/vocdoni/admin/dashboard_spec.rb`: "Verify roots" shows only while `csp_state` is nil, and both buttons enqueue their job;
  - `security.test.js`: a locked fieldset stays disabled after switching to the secret vote.

The gem has no `spec/system`; these specs are request and jest specs.

Commands:
```
bundle exec rspec spec/lib/decidim/elections/vocdoni/voting_backend_spec.rb spec/jobs/decidim/elections/vocdoni/purge_csp_pins_job_spec.rb spec/requests   # 0 failures
npx jest app/packs/src/decidim/elections/vocdoni/admin   # 0 failed
bundle exec i18n-tasks unused && bundle exec i18n-tasks missing   # clean
bundle exec rubocop   # no offenses
```
Commit: `feat(booth): sign through decidim csp endpoints and support per-question elections`.

### T10 — G4: booth adapter JS (gem)

Files (`app/packs/src/decidim/elections/vocdoni/voter/`):
- `csp_client.js` (new):
  ```js
  const csrf = () => document.querySelector('meta[name="csrf-token"]')?.content ?? "";
  async function call(url, method, body) {
    const res = await fetch(url, { method, credentials: "same-origin",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf(), Accept: "application/json" },
      body: body ? JSON.stringify(body) : undefined });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new CspError(data.error ?? `http_${res.status}`, res.status);
    return data;
  }
  export const cspStatus = (cfg) => call(cfg.statusUrl, "GET");
  export const cspSign = (cfg, questionId, address) => call(cfg.signUrl, "POST", { questionId, address });
  export const cspConfirm = (cfg, questionId) => call(cfg.confirmUrl, "POST", { questionId });
  ```
- `cast.js`:
  - replace `client.processes.sign` (`:131-139`) with `cspSign(config, questionId, signer.address)`;
  - `votingClient.vote({ …, proofType: ProofCA_Type.ECDSA, cspSignature: signed.signature, cspWeight: "01" })` (`:146-156`), with `ProofCA_Type` imported from `@vocdoni/api-voting`;
  - after the job completes, call `cspConfirm`.
  - Ephemeral key: `sessionStorage["vocdoni.csp." + upstreamId + "." + questionId]` holds the private key hex. It is written **before** `cspSign` and removed after the job completes, and a retry reuses it (`new EphemeralSigner(fromHex(stored))`).
  - Map `address_pinned` to a new `ErrorCode.ADDRESS_PINNED` with the message "contact the organiser".
- `booth_adapter.js`:
  - remove OTP/auth session (`:61-121`);
  - `prepare` calls `cspStatus`;
  - `receipts` (`:171,179`) and `recheck` (`:255-265`) read `cspStatus`; `recheck` first POSTs `cspConfirm` for pins with `!hasVoted`;
  - receipt nullifier = `keccak256(address ‖ upstreamId)` (or the server's `nullifier`);
  - `upstreamId` comes only from `booth_config`.
- `flow.js`: drop `processes.check` (`:134-149`) and `signInfo` (`:178-188`). With `perQuestion`, show only `votingEnabled` questions and poll `statusUrl` every 10 s for the next.
- Delete `auth_session.js`, `auth_step.js`, `otp_step.js`, `two_fa*.js`, `resend_cooldown.js`, `link_code.js` and their tests, as far as nothing else imports them (`rg` first).
- `csp_bundle.test.js` (jest): reads `spec/fixtures/csp/csp-external-v2-ecdsa.json`; `toHex(encodeCaBundle({processId, address, weight: "01"}))` equals `bundle` (59 bytes). The bundle the booth builds for `vote()` equals it too, via `buildCaBundle`.
- Update `booth_adapter.test.js` and `flow.test.js` for the new flow: sign → vote with ECDSA → confirm; `address_pinned` path; sessionStorage reuse on retry; per_question polling.
- Rebuild `public/vocdoni/booth-adapter.js`.

Commands:
```
npx jest app/packs/src/decidim/elections/vocdoni/voter   # Tests: N passed, 0 failed
npm run lint                                             # 0 problems
node build/booth_adapter.mjs && git diff --stat public/vocdoni/booth-adapter.js   # rebuilt bundle changed
```
Commit (explicit paths include the rebuilt bundle): `feat(booth): cast with decidim csp signatures and ecdsa proofs`.

### T11 — fork hooks (fork)

Branch `feat/external-csp`.

Files (`decidim-elections/`):
- `app/controllers/decidim/elections/votes_controller.rb:10-12`:
  ```ruby
  before_action do
    redirect_to Decidim::EngineRouter.main_proxy(current_component).new_election_per_question_vote_path(election) if election.per_question? && !voting_backend.client?
  end
  ```
  The `booth` action then serves `per_question` elections for client backends.
- `app/controllers/decidim/elections/per_question_votes_controller.rb`: once per_question elections reach the booth, `/per_question_votes/*` must not stay open for client backends, or a voter could record a server-side `CastVotes` vote that never reaches the chain. Add, before the other `before_action`s:
  ```ruby
  # A client-side backend casts from the booth; the server-side per-question steps would record a
  # vote the backend never sees.
  before_action do
    redirect_to booth_election_votes_path(election) if voting_backend.client? && !request.format.json?
  end
  ```
  The JSON `show` (the question-status poll, `:97-106`) stays open, because it reads status and writes nothing.
- `app/helpers/decidim/elections/application_helper.rb:62-65`: `voted_by_current_user?` calls `election.voting_backend.voted?(election, voter_uid)` when the backend is a client backend, and keeps `election.votes` otherwise. `ElectionsController` does not include `UsesCensusAccess`, so there is no `voter_uid` helper on the election page. The helper computes it the way it does today (`:63`): `voter_uid = session[:voter_uid] || election.census.voter_uid(election, session[:session_attributes] || {}, current_user:)`.
- Specs:
  - `spec/controllers/decidim/elections/votes_controller_spec.rb`: per_question + client backend → booth is not redirected; per_question + server backend → redirected as before;
  - `spec/controllers/decidim/elections/per_question_votes_controller_spec.rb`: client backend → HTML `show`/`update`/`receipt` redirect to the booth and no vote is stored; JSON `show` still answers; server backend → unchanged;
  - `spec/helpers/decidim/elections/application_helper_spec.rb`: the client backend's `voted?` is used, with `voter_uid` taken from the census session attributes when `session[:voter_uid]` is unset.

  Register a dummy client backend in the spec, as `booth_spec.rb` does.

Commands:
```
cd decidim-elections && bundle exec rake test_app   # once per clone
bundle exec rspec spec/controllers/decidim/elections/votes_controller_spec.rb spec/controllers/decidim/elections/per_question_votes_controller_spec.rb spec/controllers/decidim/elections/booth_spec.rb spec/helpers   # 0 failures
bundle exec rubocop app/controllers/decidim/elections/votes_controller.rb app/controllers/decidim/elections/per_question_votes_controller.rb app/helpers/decidim/elections/application_helper.rb   # no offenses
```
Commit: `feat(elections): serve per-question elections from client booths and ask the backend who voted`.

### T12 — E2E on the dev Decidim instance against the dev SaaS / DEV/36

Prerequisite: S1a+S1b deployed to a dev SaaS instance with `VOCDONI_EXTERNAL_CSP_ORIGIN=OFF_CHAIN_CA_V2`, and `externalCspAllowed` set for the dev org.

1. **Dev SaaS deploy and org flag.** Deploy saas branches S1a+S1b to a dev SaaS instance. Set `externalCspAllowed: true` on the dev org via the DB.
2. **Dev root and pin secret.** Generate a 32-byte root and pin secret (`openssl rand -hex 32` for each) and add them to the Decidim instance's environment (`VOCDONI_CSP_ROOTS=<id>:<hex>`, `VOCDONI_CSP_PIN_SECRET=<hex>`). Set `VOCDONI_CHAIN_API_URL` to the DEV chain API URL. Use `umask 077` when writing secrets to env files. Add the resulting root id to `NON_PROD_ROOT_IDS` in a follow-up gem commit: `chore(csp): deny the dev root id on lts`.
3. **Deploy and migrate.** Run `bin/rails decidim_elections_vocdoni:install:migrations && bin/rails db:migrate`. Set `VOCDONI_CSP_BOOT_CHECK=1` in the web process start command only (not in a shared env file that `db:migrate` also loads). After restart, the boot log shows `csp_root_id=<id>`, and both DB triggers exist (`decidim_vocdoni_csp_pins_guard`, `decidim_vocdoni_csp_pins_no_truncate`).
4. **Scenarios.** Record election ids, upstream ids and tx hashes. Sizes follow deviation 10 (headroom h = `VOCDONI_CENSUS_HEADROOM`, default 0.20):
   - a. **internal_users**, 2 questions, `secretUntilTheEnd`. Publish → `csp_state` verified. `GET /v2/elections/<upstreamId>` on the DEV chain API shows `censusOrigin` `OFF_CHAIN_CA_V2`, `censusRoot` = `csp_elections.census_root`, `electionMode.dynamicCensus` `false` and `maxCensusSize` = ceil(roster × (1 + h)), equal to `process.census_size`. Keep the response as evidence.
   - b. Vote both questions as user A. Votes count on chain; the receipt nullifier equals the chain vote id; `voted?` true; the hub shows "already voted".
   - c. As A, clear `sessionStorage` and vote again → `address_pinned` shown, no second vote.
   - d. **Census growth:** authorise new users until the roster exceeds `process.census_size` (with h = 0.20 and roster r, that is ceil(1.2·r) − r + 1 users; or run this scenario on an election published with `VOCDONI_CENSUS_HEADROOM=0`, where one user suffices). The next of them signs → `ResizeCensusJob` → chain `maxCensusSize` = ceil(new roster × (1 + h)) with the root unchanged, and `process.census_size` equals it only after the chain shows it. That voter votes. While the resize is in flight, `csp_state` stays verified.
   - e. **per_question** election: enable Q1 → vote; Q2 hidden until enabled; publish results Q1 → that chain election ENDED, results synced. `/per_question_votes/*` HTML pages redirect to the booth.
   - f. **token_csv** election: a CSV voter votes via the census session with no account. `maxCensusSize` = the exact row count (no headroom).
   - g. On a dev process, SaaS `POST /processes/{id}/sign` and `/auth` → 409 40185.
   - h. Purge job run manually on a finished election → addresses NULL, counts kept.
5. Repeat a–c on a sequencer/LTS-like chain (STG) when S1a+S1b reach it. This is a go/no-go item.

Report: the scenario table with pass/fail and chain evidence links.

## Merge and release

**PR order**
1. saas **S1a** `feat/csp-per-question-roots` → `main` (draft → ready after `make test`). Merged by the saas-backend owner.
2. **#796 rebases onto S1a** (owner decision 4; #796 author). Its `QuestionPublishedParams`/`questionCensusRoot`/`assignCensus` then come from S1a. The shapes differ, so this is not a plug-in rebase: see T1's rebase note.
3. saas **S1b** `feat/external-csp`: opened against S1a's branch, retargeted to `main` after S1a merges, and rebased if #796 lands first.
4. gem and fork `feat/external-csp` → `demo/integrated-booth` as drafts. **Merge only after the 2026-11-11 demo**, with owner OK (deviation 9). The gem PR states that it needs saas S1b on the target SaaS.
5. LTS: the release owner cherry-picks S1a+S1b to `lts` (backports only, owner-chosen). Request it once both are on `main`.

**Needs the owner's OK**
- a dev SaaS deploy of S1a+S1b;
- setting `externalCspAllowed` on any org (dev or prod);
- merging any of the PRs;
- the gem/fork merge timing;
- generating and installing the prod root and pin secret (custody by Vocdoni ops, design §11.2);
- the LTS backport request;
- flipping `VOCDONI_EXTERNAL_CSP_ORIGIN` to `OFF_CHAIN_CA_V3_ECDSA` when sequencer #13 deploys (gem `VOCDONI_EXTERNAL_CSP_ORIGIN` in the same window);
- telling the pilot organisation that votes are not anonymous towards Decidim.

**Rollback**
- **saas.** S1b is inert unless an org has `externalCspAllowed`. Unset the flag to stop new external processes. Published external elections keep relaying (relay unchanged). S1a preserves legacy behaviour; revert its commits if needed (the per-question fields are `omitempty`, so no data migration).
- **gem/fork.** Revert the merge commits on `demo/integrated-booth` to return new elections to the SaaS CSP/OTP booth. Already-published external elections cannot switch to the SaaS key (the root is immutable): end them and republish. Keep the pins tables (the migration is irreversible by design).
- **`VOCDONI_INTEGRATED_BOOTH=false` is not a rollback for external-CSP elections.** It sends voters to the static SPA (`RedirectsVoterToBooth`), which authenticates and signs through the SaaS, and the SaaS answers 409 on auth and sign for an external census. Use it only for elections published before the gem branch was deployed.
- **Compromised root.** End the affected elections, add a new root as the last keyring entry (it applies only to new publishes), and republish. Never edit or delete pins.
