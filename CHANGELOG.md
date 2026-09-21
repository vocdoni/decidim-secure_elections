# Changelog

All notable changes to this module are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the module follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Security tab** injected into the upstream `decidim-elections` admin (Main,
  Questions, Census, Security, Dashboard). Owns the Vocdoni opt-in and the
  second-factor challenge — email OTP, SMS OTP, both, or none.
- **`Decidim::Elections::Vocdoni::Process` sidecar** (`decidim_vocdoni_processes`
  table) keyed to `Decidim::Elections::Election`. Its presence is the opt-in
  signal; it carries the Vocdoni process id, chain id, member-group id and a
  per-question metadata bag.
- **`PublishElectionJob`** — subscribes to upstream's
  `publish_election`/`update_election_status` events, pushes the roster to the
  Vocdoni memberbase, builds a member group, validates the census, creates and
  publishes the process on chain. Manual-start elections push at Start-time;
  scheduled elections push at `start_at`. Reschedules itself when the admin
  moves `start_at`.
- **`SyncProcessJob`** — mirrors the on-chain state of a published process into
  the sidecar so the admin dashboard reads from local columns rather than the
  SaaS.
- **`EndProcessOnChainJob`** — subscribes to
  `update_election_status:after` with `action == :end` and moves every
  question of the Vocdoni process to status `ENDED` via
  `PUT /processes/{id}/questions/status`, so clicking "End election" in the
  admin also closes the process on chain (final tally, explorer flips out of
  "Voting open / Provisional"). Chains a `SyncElectionResultsJob` so the
  tally auto-populates once the chain has decrypted it.
- **`SyncElectionResultsJob`** — subscribes to
  `update_election_status:after` with `action == :publish_results` and pulls
  `GET /processes/{id}/results` from the SaaS, mirroring the on-chain tally
  into `Decidim::Elections::ResponseOption#votes_count` so the Decidim
  results view stops rendering 0/0/0 after publish. Reschedules itself on a
  bounded cadence (30 attempts × 120 s) until every question reports
  `finalResults: true` — required for `secretUntilTheEnd` elections whose
  chain-side tally is only decrypted after ENDED, on the order of minutes,
  without any SaaS event to notify.
- **`ApiClient`** — Ruby client for the Vocdoni SaaS REST API, no Node.js
  runtime on the server. Elections, organizations and async jobs surfaces.
- **Static in-browser voting page** under `public/vocdoni/vote.html`, served by
  middleware. Census authentication, ephemeral key generation, ballot encoding
  and vote relay all run in the voter's browser against the Vocdoni API. The
  Decidim server never sees a ballot.
- **`decidim_elections_vocdoni:create_organization`**,
  **`decidim_elections_vocdoni:doctor`** and
  **`decidim_elections_vocdoni:purge_stale_drafts`** rake tasks.

### Security

- The integrator API key is server-side only and is never sent to the browser;
  the voter path uses only public and CSP-token routes.
- `Decidim::Elections::Vocdoni.validate_configuration!` raises on an incomplete
  configuration instead of falling back to a default (test) chain.
- The voting page talks only to an API on an allowed origin (the Vocdoni SaaS
  bases it ships with, its own origin, or loopback), so a hand-crafted link on
  the installation's own domain cannot turn the census form into a credential
  collector.
- Nothing from a voting session is written to storage, a cookie, the URL or a
  session — no auth token, no one-time code, no ballot.
