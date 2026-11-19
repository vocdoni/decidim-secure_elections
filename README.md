# decidim-elections-vocdoni

An optional security layer for the upstream [`decidim-elections`](https://github.com/decidim/decidim/tree/develop/decidim-elections)
module: sends ballots to the [Vocdoni](https://vocdoni.io) voting network
instead of storing them in the Decidim database. Voters vote in Decidim's own
booth, whose `vocdoni` voting backend talks to Vocdoni from the browser.

The gem is hosted at
[vocdoni/decidim-secure_elections](https://github.com/vocdoni/decidim-secure_elections);
the repository still carries the older name.

## How it fits in

`decidim-elections` gives an election four admin tabs: **Main**, **Questions**,
**Census**, **Dashboard**. This gem adds a fifth tab, **Security**, between
Census and Dashboard, where the admin opts an election into Vocdoni and picks
the second-factor challenge.

Opting in is materialised by a `Decidim::Elections::Vocdoni::Process` sidecar
row keyed to the upstream `Decidim::Elections::Election`. Its presence is the
opt-in signal; upstream's own tables and models are not touched.

- **When voting starts** (at `start_at` for a scheduled election, when the
  admin clicks Start for a manual-start one), `PublishElectionJob` creates and
  publishes the process on chain with an attested census and mirrors the
  resulting Vocdoni ids back onto the sidecar. No roster leaves Decidim: the
  census declares the election's signer and a maximum size of
  ceil(eligible × 1.2), and Decidim signs an EIP-712 attestation for each
  eligible voter when they open the booth, so participants who join the
  census later can vote while that maximum has room. The one-time code goes
  by email or by SMS, never both; SMS needs each voter's phone in
  international format (`+34 600 123 456`), see `docs/architecture.md` §4c.
- **On the voter side**, Decidim's booth runs the `vocdoni` voting backend for
  Vocdoni-backed elections: the booth adapter served from
  `public/vocdoni/booth-adapter.js` does census authentication, ballot encoding
  and vote relay in the browser against the Vocdoni API. Upstream's server-side
  voting wizard never takes a ballot for these elections.

The Rails server holds an integrator API key and does only *organiser* work.
No ballot, no voting key and no API key ever leaves it or reaches the browser.

## Requirements

- Decidim `~> 0.33` (with `decidim-elections`) with client-side voting backends
  (`Decidim::Elections.voting_backends`), as in [vocdoni/decidim](https://github.com/vocdoni/decidim)
- Ruby `~> 3.4`
- PostgreSQL
- Redis and an ActiveJob backend with a **running worker** listening on the
  `vocdoni` queue (Sidekiq in the reference deployment)
- A Vocdoni SaaS account with an **integrator API key** (`vsk_…`) and a
  **managed organization address** (`0x…`)

## Installation

### 1. Add the gem

```ruby
# Gemfile
gem "decidim-elections-vocdoni",
    git: "https://github.com/vocdoni/decidim-secure_elections"
```

### 2. Install and migrate

```bash
bundle install
bin/rails decidim_elections_vocdoni:install:migrations
bin/rails db:migrate
```

### 3. Configure the credentials

Copy `.env.example` from this repository and fill in the three required values:

```bash
VOCDONI_API_URL=https://saas-api.vocdoni.net
VOCDONI_API_KEY=vsk_…
VOCDONI_ORG_ADDRESS=0x…
```

There is deliberately no default `VOCDONI_API_URL`. In production, prefer
Rails encrypted credentials for the key (`vocdoni.api_key`).

To mint an org address once against a configured API key:

```bash
bin/rails decidim_elections_vocdoni:create_organization["My organization"]
```

Check the whole configuration and reachability with:

```bash
bin/rails decidim_elections_vocdoni:doctor
```

### 4. Give the worker the `vocdoni` queue

Every call to the Vocdoni SaaS runs as a background job on its own queue, so a
slow network call cannot starve mail or search indexing. The queue must be
one your worker actually processes:

```yaml
# config/sidekiq.yml
:queues:
  - [vocdoni, 3]
  - [default, 2]
```

A worker that is not listening on `vocdoni` silently queues publish and sync
jobs forever. `decidim_elections_vocdoni:doctor` catches this on Sidekiq.

## Configuration reference

| Setting | ENV var | Required | Purpose |
|---|---|---|---|
| `api_url` | `VOCDONI_API_URL` | yes | Vocdoni SaaS base URL. Production `https://saas-api.vocdoni.net`; staging `https://saas-api-stg.vocdoni.net`; development `https://saas-api-dev.vocdoni.net`. |
| `api_key` | `VOCDONI_API_KEY` (or credential `vocdoni.api_key`) | yes | Integrator API key. Server-side only. |
| `org_address` | `VOCDONI_ORG_ADDRESS` | yes | Address of the managed organization the processes belong to. |
| `explorer_url` | `VOCDONI_EXPLORER_URL` | no | Explorer for receipt checks and the per-question election links. Derived from `api_url` so the two cannot disagree. Set it only for a self-hosted network. |
| `open_timeout` | `VOCDONI_OPEN_TIMEOUT` | no | HTTP connect timeout, in seconds. Default `5`. |
| `timeout` | `VOCDONI_TIMEOUT` | no | HTTP read timeout, in seconds. Default `30`. |
| `job_timeout` | `VOCDONI_JOB_TIMEOUT` | no | How long a background job waits for an async SaaS job before giving up. Default `120`. |

An initializer works too:

```ruby
# config/initializers/vocdoni.rb
Decidim::Elections::Vocdoni.configure do |config|
  config.api_url = "https://saas-api.vocdoni.net"
  config.org_address = "0x…"
end
```

A misconfigured deployment fails loudly (`ConfigurationError`) rather than
falling back to a test chain.

## Where things live

| | |
|---|---|
| Ruby namespace | `Decidim::Elections::Vocdoni` |
| Gem name | `decidim-elections-vocdoni` |
| Repository | `vocdoni/decidim-secure_elections` |
| Sidecar table | `decidim_vocdoni_processes` |
| Booth adapter | `public/vocdoni/booth-adapter.js` (served by middleware) |
| Background jobs | queue `:vocdoni` — `PublishElectionJob` (lands the election on chain at start); `SyncProcessJob` (polls on-chain state while voting is open); `SyncElectionResultsJob` (writes tally into Decidim after publish-results); `SyncResultsAfterVoteJob` (live-tally chain for `real_time` elections); `EndProcessOnChainJob` (moves every question to ENDED when the admin ends the election); `UpdateQuestionOnChainJob` (opens or closes a single `per_question` question) |

The booth adapter is a committed build artefact under `public/vocdoni/`.
Rebuild it with `npm run build:booth` and commit the result whenever anything
under `app/packs/src/decidim/elections/vocdoni/voter/` or the npm dependencies
change.

## Architecture

The design notes — trust boundary, invariants, Vocdoni SaaS API quirks, voter
flow, two-factor behaviour — are in [docs/architecture.md](docs/architecture.md).
Source comments cite it by section (`ARCHITECTURE §N`).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues go to
[SECURITY.md](SECURITY.md).

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE).
