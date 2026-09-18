# decidim-elections-vocdoni

An optional security layer for the upstream [`decidim-elections`](https://github.com/decidim/decidim/tree/develop/decidim-elections)
module: sends ballots to the [Vocdoni](https://vocdoni.io) voting network
instead of storing them in the Decidim database, and hands voters to a static
in-browser voting page that talks to Vocdoni directly.

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

- **On publish**, an upstream notification triggers `PublishElectionJob`, which
  pushes the roster to the Vocdoni memberbase, builds a member group, validates
  the census, creates and publishes the process on chain, and mirrors the
  resulting Vocdoni ids back onto the sidecar. Manual-start elections push at
  Start-time; scheduled elections push at `start_at`.
- **On the voter side**, upstream's `Decidim::Elections::VotesController` is
  hijacked for Vocdoni-backed elections: the voter is handed to the static
  voting page served from `public/vocdoni/vote.html`, which does census
  authentication, ballot encoding and vote relay in the browser against the
  Vocdoni API.

The Rails server holds an integrator API key and does only *organiser* work.
No ballot, no voting key and no API key ever leaves it or reaches the browser.

## Requirements

- Decidim `~> 0.33` (with `decidim-elections`)
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
| `explorer_url` | `VOCDONI_EXPLORER_URL` | no | Derived from `api_url` so the two cannot disagree. Set it only for a self-hosted network. |
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
| Static voting page | `public/vocdoni/vote.html` (served by middleware) |
| Background jobs | `PublishElectionJob`, `SyncProcessJob` (queue `:vocdoni`) |

The static voting page is a committed build artefact under `public/vocdoni/`.
Rebuild it with `npm run build:vote` and commit the result whenever anything
under `app/packs/src/decidim/elections/vocdoni/voter/` or the voting-page
strings in `config/locales/` change.

## Architecture

The design notes — trust boundary, invariants, Vocdoni SaaS API quirks, voter
flow, two-factor behaviour — are in [docs/architecture.md](docs/architecture.md).
Source comments cite it by section (`ARCHITECTURE §N`).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues go to
[SECURITY.md](SECURITY.md).

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE).
