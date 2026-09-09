# decidim-secure_elections

Verifiable elections for [Decidim](https://decidim.org), run on the
[Vocdoni](https://vocdoni.io) protocol.

The module adds a **Secure elections** component to any participatory space.
An admin builds an election in a linear wizard, publishes it to the Vocdoni
network, and participants vote from a page that runs entirely in their own
browser. The tally is read back from the chain and can be checked by anybody,
including from the CSV/JSON export, without trusting this Decidim installation.

## Trust model

This is the part worth reading before anything else.

**The server never sees a ballot.** Decidim holds an integrator API key and
performs only *organiser* operations over HTTPS: create a process, publish it,
move question status, read the tally. The voter's browser does everything else
itself against the same public Vocdoni API — census authentication, ephemeral
key generation, ballot encoding, vote signing and relay. No API key is ever
sent to the browser, and no ballot, no choice and no voting key ever reaches
Rails. The only thing the server learns is what the chain already publishes:
how many votes were cast.

**There is no Node.js runtime on the server.** Reaching the Vocdoni SDK by
shelling out to Node would mean a second runtime to install, to secure and to
keep alive, and a subprocess boundary that handles ballots. This module talks to
the Vocdoni SaaS REST API directly from Ruby with Faraday instead. Node is
needed only at *build* time, to compile the JavaScript packs — the same Node
your Decidim application already uses for Shakapacker.

**No API call happens inside a web request.** Every write and every slow read
goes through ActiveJob (`PublishElectionJob`, `SetQuestionStatusJob`,
`SyncResultsJob`). Pages read cached columns, so a busy election page never
fans out into upstream requests. A background worker is therefore **required**,
not optional.

**Misconfiguration fails loudly.** There is no default API URL. An installation
that has not been configured raises `Decidim::SecureElections::ConfigurationError`
rather than quietly running a real election against a test chain.

### What each side knows

| | Decidim server | Voter's browser | Vocdoni |
|---|---|---|---|
| Integrator API key | yes | never | yes |
| Voter's census identity (member number, email, …) | never stored | entered by the voter, sent to the API | yes |
| Ballot contents | never | yes | encrypted / on chain |
| Vote receipt (nullifier) | never | yes | yes |
| Vote counts | cached copy of the public tally | yes | yes |

## A note on two names

The gem is `decidim-secure_elections` and the Ruby namespace is
`Decidim::SecureElections`. You will still see `vocdoni` in a number of places,
and the split is deliberate: **the gem is named after what it does, and
`vocdoni` is kept wherever the thing being named actually belongs to the Vocdoni
network rather than to this module.**

Stays `vocdoni`:

| Where | Example | Why |
|---|---|---|
| Database tables and columns | `decidim_vocdoni_elections`, `vocdoni_process_id`, `vocdoni_upstream_id` | These hold identifiers minted by Vocdoni. Renaming the tables around them would be a migration that reads as if the data had changed meaning. |
| Environment variables | `VOCDONI_API_URL`, `VOCDONI_API_KEY` | They configure the Vocdoni API, not this module. |
| Component manifest | `:vocdoni`, and the `decidim.components.vocdoni.*` strings keyed off it | It is written into `decidim_components.manifest_name` for every component already created. |
| The voting page URL | `/vocdoni/vote.html` | Links to it are minted into emails and printed sheets. |
| Test factories | `:vocdoni_election`, `:vocdoni_component` | Named after the component, as Decidim names factories. |
| CSS classes | `.vocdoni-button`, `.vocdoni-choice` | Private selectors, asserted by the voting page's own tests and baked into its committed build. |

Follows the gem: the Ruby namespace, every file path, the engine, the rake tasks
(`decidim_secure_elections:install:migrations`), the Shakapacker entrypoints and
this module's own locale tree (`decidim.secure_elections.*`).

## Requirements

- Decidim `0.33.x`
- Ruby `~> 3.4` (Decidim 0.33 runs on 3.4.7)
- PostgreSQL
- Redis and an ActiveJob backend with a **running worker** (Sidekiq in the
  reference deployment). Every job in this module is queued as `vocdoni`, which
  is deliberately separate so that a slow chain call cannot starve mail or
  search indexing — but it does mean you must add the queue to the worker, or
  publishing an election will silently sit at "publishing" forever:

  ```yaml
  # config/sidekiq.yml
  :queues:
    - [vocdoni, 3]   # <- add this
    - [default, 2]
    # …
  ```

  Verify with `bin/rails decidim_secure_elections:doctor`, which checks configuration and
  connectivity in one go.
- Node 24.x — build time only, for compiling the packs
- A Vocdoni SaaS account with an **integrator API key** (`vsk_…`) and a
  **managed organization address** (`0x…`)

## Installation

### 1. Add the gem

```ruby
# Gemfile
gem "decidim-secure_elections"
```

While Decidim 0.33 is distributed from its development branch, point at the same
branch this module is built against:

```ruby
# Gemfile
git "https://github.com/decidim/decidim", branch: "develop" do
  gem "decidim"
  # …and the other decidim-* gems your application uses
end

gem "decidim-secure_elections", git: "https://github.com/vocdoni/decidim-secure_elections"
```

### 2. Install and migrate

```bash
bundle install
bin/rails decidim_secure_elections:install:migrations
bin/rails db:migrate
```

### 3. Configure the credentials

The module needs three values, and refuses to run without them. Put them in the
environment or in Rails encrypted credentials — see
[Configuration](#configuration) for the full list and for how to obtain an
organization address.

```bash
VOCDONI_API_URL=https://saas-api.vocdoni.net
VOCDONI_API_KEY=vsk_…
VOCDONI_ORG_ADDRESS=0x…
```

Check them with:

```bash
bin/rails decidim_secure_elections:doctor
```

### 4. Give the worker the queue

Every call to Vocdoni runs as a background job on its own `vocdoni` queue, so a
slow network call cannot starve mail or search indexing. The queue has to be one
your worker actually processes:

```yaml
# config/sidekiq.yml
:queues:
  - [vocdoni, 3]
  - [default, 2]
```

### 5. Compile the assets and restart

```bash
bin/rails assets:precompile   # or `bin/dev` in development
```

Restart the web process **and** the worker. A **Secure elections** component is
then available in the "Add component" list of every participatory space.

### What you do not have to do

- **No npm package, no Shakapacker entrypoint, no copy step.** The module ships
  `config/assets.rb` and Decidim loads the asset configuration of every
  `decidim-*` gem in the bundle by itself.
- **Nothing at all for the voting page.** It is a self-contained static page
  shipped inside the gem — one HTML file, one JavaScript bundle with the Vocdoni
  SDK compiled in, one stylesheet, one font and one JSON file per locale — and
  the engine serves it straight off disk at `/vocdoni/vote.html?v=<packed>`.

  `v` packs the API base URL, the process id and, when present, the locale and
  the "back to the election" path into one short base64url value, so the link
  fits on one line of an email. It is an abbreviation rather than a secret:
  anybody can decode it, and everything in it is public. The spelled-out
  `?api=…&process=…&locale=…&exit=…` form is accepted too.

  The **Vote** button on the election page and the **Voting links** panel in the
  admin build the link for you.

### Upgrading

```bash
bundle update decidim-secure_elections
bin/rails decidim_secure_elections:install:migrations
bin/rails db:migrate
bin/rails assets:precompile
```

Restart both the web process and the worker. Anything a release needs you to do
beyond this is in [CHANGELOG.md](CHANGELOG.md).

Elections already on the Vocdoni network are unaffected by an upgrade: they live
on the network, and the tally can always be read back from it.

## Configuration

All settings live on `Decidim::SecureElections` and are resolved on first read, so they
can come from the environment, from Rails encrypted credentials, or from an
initializer.

| Setting | ENV var | Credential | Required | Default | Purpose |
|---|---|---|---|---|---|
| `api_url` | `VOCDONI_API_URL` | — | **yes** | *none* | Base URL of the Vocdoni SaaS API. Development: `https://saas-api-dev.vocdoni.net`. Staging: `https://saas-api-stg.vocdoni.net`. Production: `https://saas-api.vocdoni.net`. There is deliberately no default. |
| `api_key` | `VOCDONI_API_KEY` | `vocdoni.api_key` | **yes** | *none* | Integrator API key (`vsk_…`). Server-side only. Credentials take precedence over the environment. |
| `org_address` | `VOCDONI_ORG_ADDRESS` | — | **yes** | *none* | Address (`0x…`) of the Vocdoni organization that owns the processes this installation creates. |
| `explorer_url` | `VOCDONI_EXPLORER_URL` | — | no | derived from `api_url` | Public explorer a voter follows to check their receipt, and the target of the verification links in the results export. Derived from the API base so the two can never disagree: the production API implies `https://explorer.vote`, staging implies `https://stg.explorer.vote`, development implies `https://dev.explorer.vote`. Set it only for a self-hosted network. |
| `open_timeout` | `VOCDONI_OPEN_TIMEOUT` | — | no | `5` | Connect timeout, in seconds. |
| `timeout` | `VOCDONI_TIMEOUT` | — | no | `30` | Read timeout, in seconds. |
| `job_timeout` | `VOCDONI_JOB_TIMEOUT` | — | no | `120` | How long a background job waits for an async Vocdoni job (publish, status change) before giving up. |

`.env.example`, in the repository rather than in the gem, is a ready-to-copy
template. It leaves `VOCDONI_API_URL` **empty on purpose**: a template that
arrived pre-filled with the staging API would be one careless copy away from
running a real election on a test chain.

The voting page only talks to an API on an origin it is allowed to — one of the
Vocdoni SaaS bases it ships with, the installation's own origin, or loopback.
This is what stops a hand-crafted link on your own trusted domain from
collecting census credentials. If you run the API somewhere else, the page has
to be rebuilt with that origin in `API_HOSTS`
(`app/packs/src/decidim/secure_elections/voter/link_code.js` and its Ruby twin
`Decidim::SecureElections::VotingPageUrl::API_HOSTS`); it is a deliberately manual step.

In production, prefer credentials for the key:

```bash
bin/rails credentials:edit
```

```yaml
vocdoni:
  api_key: vsk_xxxxxxxxxxxxxxxx
```

An initializer works too, and takes precedence over both:

```ruby
# config/initializers/vocdoni.rb
Decidim::SecureElections.configure do |config|
  config.api_url = "https://saas-api.vocdoni.net"
  config.org_address = "0x…"
  config.explorer_url = "https://explorer.vote"
end
```

Never assign these to `ENV` at runtime — the module reads configuration
explicitly and secrets must not end up in process-global state.

To check the configuration from a console:

```ruby
Decidim::SecureElections.configured?            # => true
Decidim::SecureElections.validate_configuration! # raises and names what is missing
```

### Content Security Policy

The voting page is served by middleware rather than by a controller, so
Decidim's `Content-Security-Policy` — whose default `connect-src 'self'` would
block every request it makes — never applies to it. If you add a policy of your
own in front of the application (a reverse proxy, a CDN), exempt
`/vocdoni/vote.html` or allow `connect-src` to your Vocdoni API origin, or
voting will fail silently in the browser.

## Obtaining an `orgAddress`

Every process this installation creates belongs to one *managed organization* in
Vocdoni. You create it once and put its address in `VOCDONI_ORG_ADDRESS`:

```bash
bin/rails decidim_secure_elections:create_organization["My organization"]
# => VOCDONI_ORG_ADDRESS=0x…
```

Set it, restart, and check everything with:

```bash
bin/rails decidim_secure_elections:doctor
```

That is the **only** Vocdoni identifier you ever handle. Members, groups and
censuses are all created for you — the admin interface never asks for, and
cannot accept, a Vocdoni id.

## Admin walkthrough

Add a **Secure elections** component to a participatory space, then create an
election. Setting one up is a **five-step sequence**, and a strict one: a step
only opens once every step before it is complete.

```
1. Details  →  2. Questions  →  3. Census  →  4. Schedule  →  5. Publish  →  Monitor
```

Locked steps stay visible and say what is missing rather than disappearing, so
you can always see what is left to do. The order is enforced in three
independent places — the navigation disables the step, the controller redirects
a typed URL to the furthest step you can actually work on, and the permission
class withholds its grant — because a greyed-out link is not access control.

Once an election is on the blockchain the four content steps stay reachable and
turn **read-only**: nothing can be changed, but you can still see exactly what
was published.

### 1. Details

`Elections → New election` asks for a **title** — that is all it takes to bring
an election into existence — plus an optional **video** URL and a rich-text
**description**. Drafts autosave; leaving with unsaved changes asks first.

### 2. Questions — the ballot

Questions **and** their options are on one screen, added, removed and reordered
without a page reload and saved in a single submit.

- **Templates** — *Annual General Meeting*, *Election*, *Participatory
  Budgeting* prefill a starting ballot. Offered only while the ballot is still
  empty, so they cannot throw away work.
- **Question type** — one control that applies to every question. Each question
  still becomes its own election on the blockchain.
- **Result visibility** — live, or hidden until the end and the keys are
  published.
- Each question has a title, an optional description, its options and — for
  multiple choice — selection limits.

Drafts autosave here too, ids and all, so a half-written ballot is never a
ballot lost.

### 3. The census — who may vote

`Census` has two halves.

**Voter authentication** decides what a voter must produce to prove they are on
the census:

- **Credentials** — up to three member fields (name, surname, member number,
  national ID, birth date). More fields means a stronger identity check; the
  screen advises as you pick.
- **Two-factor** — off, by **email**, by **SMS**, or the **voter's choice** of
  the two. With 2FA on, the contact field becomes required for every person,
  because the voter has to supply it and it must match.

  > Email two-factor has been exercised end to end, against the live network,
  > through to a recorded vote. **SMS has not.** It is implemented and the API
  > accepts the configuration, but no vote has been cast through it. If you are
  > running an election that matters, use email, or prove SMS on a rehearsal
  > election of your own first.
- A **security meter** rates the result *weak*, *mid* or *strong* — 2FA is what
  makes it strong.

A census with no credentials and no two-factor identifies nobody, and is refused.

**People** is the list itself, filled any of three ways:

1. **By hand** — add rows inline; only the columns this election actually needs
   are shown.
2. **From a CSV** — download a template containing exactly those columns, fill
   it, upload it. Rows that fail are reported with their line number and reason,
   and the rest still import.
3. **From Decidim verifications** — pull in participants who hold a given
   authorization. This is the one thing the Vocdoni app cannot do, and the reason
   this module exists.

### 4. Schedule

*Start immediately* — the election opens the instant it reaches the blockchain —
or a start time you pick, plus the required **end time**. An election with no
end can never be tallied, so it is refused.

### 5. Publish

`Publish` shows a checklist, then requires both a tick and a typed confirmation
phrase. Confirming enqueues a job that pushes the people to Vocdoni, builds a
member group, validates it, creates and publishes the census, and finally creates
and publishes the process on chain — in that order, with no admin input.

If validation fails because people are missing a required field, the job stops
**before** anything reaches the blockchain and names exactly who.

### Monitor

Once publication has been attempted, **Monitor** opens: status, turnout,
per-question results and the controls that pause, resume, end or cancel voting
on chain. Everything it renders is read from local columns, so opening it costs
no upstream request.

## Voter flow

From the public election page a participant clicks **Vote** and lands on the
voting page, a focused page whose whole flow runs client side. An organiser can
also send them straight there: the admin panel's **Voting links** panel offers
that link beside the election page's own.

1. **Identify yourself** — the voter fills in the census fields the admin
   chose. These go straight to the Vocdoni API; Decidim never stores them.
2. **One-time code**, if the election has a two-factor field — a code is sent
   by email or SMS and entered here. Elections with no two-factor field skip
   this step entirely.
3. The page asks the API what this voter may do. Not being on the census is a
   normal answer, not an error, and is shown as such — as is having already
   voted.
4. **Choose** — one screen per question, with client-side validation of the
   minimum/maximum number of picks.
5. **Review** — nothing has been sent yet; the voter can go back and change any
   answer.
6. **Cast** — for each question the browser generates a fresh ephemeral key,
   has the census sign it, encodes the ballot and relays the vote. One
   transaction per question. For a *secret until the end* question it waits
   for the encryption keys to be published and never falls back to casting in
   clear.
7. **Receipt** — each vote returns a nullifier, shown as a receipt code with a
   link to the explorer. It proves a vote was recorded; it does not reveal what
   was voted. Receipts remain retrievable later from **Check my vote receipt**
   on the election page, by authenticating again — nothing is kept in the URL
   or in a session.

The voting page requires JavaScript, and says so, because encryption and
signing happen in the browser by design.

## GraphQL API

Elections are public objects and are queryable:

```graphql
{
  participatoryProcesses {
    components {
      ... on VocdoniElections {
        elections {
          edges {
            node {
              id
              title { translation(locale: "en") }
              status
              onChain
              processId
              votesCount
              turnout
              questions {
                title { translation(locale: "en") }
                questionType
                upstreamId
                votesCount
                answers { title { translation(locale: "en") } value votesCount votesPercent }
              }
            }
          }
        }
      }
    }
  }
}
```

Census configuration (which fields identify a voter, which member group, which
two-factor channel) and module configuration are **not** exposed.

## Deployment

`docker/` holds a reference deployment. Note that the build context is your
Decidim **application** root, not this module's repository:

- `docker/Dockerfile` — Ruby 3.4.7 with Node 24.18.0 installed to `/usr/local`.
  Node has to be on the system `PATH` rather than behind a shell-init version
  manager, because Shakapacker shells out to `node` from a plain `sh`; that is
  what makes `assets:precompile` work in a non-interactive container.
- `docker/compose.yml` — `app`, `worker`, `postgres` and `redis`. The `worker`
  service is required: publishes, status changes and results syncs all run as
  background jobs.

```bash
cp path/to/decidim-secure_elections/.env.example .env
$EDITOR .env            # VOCDONI_API_URL, VOCDONI_API_KEY, VOCDONI_ORG_ADDRESS

docker compose -f path/to/decidim-secure_elections/docker/compose.yml \
  --project-directory . up -d --build
```

Override `VOCDONI_DOCKERFILE` if the module is vendored somewhere other than
`vendor/decidim-secure_elections`. The application refuses to boot an election
without the three required variables.

### Behind a TLS-terminating proxy

Set `default_url_options` in the host application to the public host and
scheme, with **no port**:

```ruby
# config/environments/production.rb
config.action_mailer.default_url_options = { host: "example.org", protocol: "https" }
Rails.application.routes.default_url_options = config.action_mailer.default_url_options
```

Links built outside a request take their scheme and port from here, not from
the request — which includes the voting link in the admin's own "Voting link"
panel. Leave it at the generated default and that panel hands an admin
`http://example.org:3000/…`: a link that neither resolves nor speaks TLS, from
the one panel in the product designed to be copied and shared. Decidim's
notification emails carry the same links.

The host itself comes from the organization, so the domain participants use
must be the organization's **primary** host. A domain listed only in
`secondary_hosts` is treated by `Decidim::Middleware::CurrentOrganization` as
an alias and answered with a 301 to the primary — so a proxy forwarding
`Host: example.org` gets redirected away rather than served.

### Serving it quickly

None of this is specific to this module, but all of it was measured on it, and
the difference on the election pages was roughly 4× (≈830 ms → ≈210 ms of
time-to-first-byte):

- **Do not serve from a reloading environment.** A Rails environment with
  `cache_classes = false` and `eager_load = false` re-checks the codebase on
  every request. This dominated everything else here.
- **Run several Puma workers**, not threads alone. Rendering a Decidim page is
  CPU-bound Ruby and the GVL admits one thread at a time to it, so processes
  are what use the other cores. `WEB_CONCURRENCY=4` on 8 cores took eight
  concurrent requests from serialised to ≈0.57 s in total.
- **Enable fragment caching and give it a shared store.** Decidim's cells cache
  heavily and this module's own cells follow suit, but with several workers an
  in-process store is one cold cache per worker. Point `config.cache_store` at
  the Redis you already run for jobs, and set an `error_handler` plus short
  timeouts so a slow cache degrades to a miss rather than to a failed page.

> **Set `HTTP_PORT` to the port participants actually use.**
> `Decidim::UrlOptionResolver` reads it and, in development, falls back to
> `3000`. That port is appended to the asset host, so packs are served from
> `//your.host:3000/…` — a different origin from the page, which Decidim's own
> `img-src 'self'` then blocks, breaking every JavaScript-loaded image. The
> resolver also reports `https` only when the port is 443 or `force_ssl` is on.
> Behind a TLS proxy, `HTTP_PORT=443` fixes both.

> **Gotcha when you turn eager loading on:** `decidim-ai` resolves its Redis URL
> at load time and falls back to `redis://localhost:6379/2`. Under lazy loading
> that code may never run at boot; under eager loading it does, and the
> application refuses to start with `Redis::CannotConnectError` unless
> `DECIDIM_SPAM_DETECTION_BACKEND_RESOURCE_URL` and
> `DECIDIM_SPAM_DETECTION_BACKEND_USER_REDIS_URL` are both set. The error names
> `localhost`, not the variable, so it is worth knowing in advance.

## Development

```bash
export DECIDIM_PATH=/path/to/decidim   # optional, to develop against a checkout
bundle install                         # without DECIDIM_PATH, tracks decidim's develop branch
bundle exec rake test_app              # generates spec/decidim_dummy_app
bundle exec rspec

npm install
npm test                               # jest, for the voting page
npm run lint                           # eslint
npm run stylelint                      # stylelint
npm run build:vote                     # rebuilds public/vocdoni — commit it
bundle exec rubocop
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the longer version.

`public/vocdoni/` is a **committed build artefact**. Rebuild and commit it
whenever you change anything under `app/packs/src/decidim/secure_elections/voter/`,
`app/packs/fonts/decidim/secure_elections/` or the `votes.page` strings in
`config/locales/` — the gem ships the built files, and the specs check they are
in step with the locale sources.

### Making the voting page match your Decidim

The voting page is standalone: it owns the whole window and cannot read the
organization's brand variables, so `vote.css` reimplements the Decidim patterns
it needs and ships with Decidim's historical primary. Two custom properties are
all you need to rebrand it:

```css
:root {
  --vocdoni-brand: #4053bf;      /* your organization's colour */
  --vocdoni-brand-ink: #ffffff;  /* the text that sits on a brand fill */
}
```

`--vocdoni-brand-ink` exists because contrast is not optional here: it must
measure at least 4.5:1 against `--vocdoni-brand`. Near-black suits a light or
mid brand colour, white suits a dark one. Everything else — the greys, the type
scale, the radii, the state colours — is Decidim's own and needs no changes.

`bundle exec rake development_app` generates and seeds a development
application. **Seeds never call the Vocdoni API**: they create local draft
elections only, so seeding works offline and without credentials. A seeded
election walks the whole wizard up to — but not through — the irreversible
publish step.

## Troubleshooting

**`Decidim::SecureElections::ConfigurationError: decidim-secure_elections is not configured`**
One of `api_url`, `api_key` or `org_address` is missing; the message names
which. Remember the worker needs them too — a web process configured through an
initializer and a worker started without it is a common split-brain.

**The election is stuck in `publishing`.**
`PublishElectionJob` did not finish. Check the worker is running and look at
the Monitor page: it shows the last background failure and offers **Resume
publication**, which continues from where it stopped without creating a second
process. If the election never reached the chain it falls back to `draft` and
becomes editable again.

**Publication fails with `invalid JSON request body` (code 40004).**
The API requires language maps for every title and description. The Ruby client
builds them; if you are calling `ApiClient` yourself, pass values through
`client.localize(...)`.

**Publication fails with code 40037.**
A question type was sent in camelCase. The API only accepts `singlechoice` and
`multichoice`, lowercase.

**Results stay at zero.**
Results come from `SyncResultsJob`, not from the page. Check the worker, then
use **Refresh** on the Monitor page. A question marked *secret until the end*
has no readable tally at all until the election ends and the encryption keys
are published — that is the feature working.

**The voter sees "This page could not start".**
That message is static English markup in `vote.html`, shown for the only two
failures that happen before the page has a vocabulary: the link did not name a
usable API and process, or `locales/en.json` could not be fetched. Check the
link first, then that `/vocdoni/locales/index.json` is being served — a reverse
proxy that only forwards `.html` will break it. Anything later fails with a
*translated* message instead. The voting page deliberately never logs ballot
data, but load and network errors do surface in the browser console.

**The voter sees "This voting link is incomplete".**
The link carried no election this page could read: a `v` that was truncated
(a mail client wrapping a long line is the usual culprit), or plain parameters
with no `api`/`process`. Reloading cannot help — mint a fresh link from the
admin panel's **Voting links** panel.

**"You are not on the census for this election".**
The details entered do not match a member of the configured group. Verify with
`client.organizations.groups(org_address)` that the group id in the census step
is right, and that every member carries the field the census authenticates on
(usually `memberNumber`), uniquely.

**A voter's vote was "not confirmed".**
The relay lost contact after the vote may already have been counted. The page
offers **Check whether my vote was recorded** rather than re-casting, because a
second attempt could double-count. Receipts are also retrievable at any time
from the election page.

## Data protection

A census is personal data, and this module puts it in your database.

- The census table (`decidim_vocdoni_census_members`) stores whatever the
  election needs to identify voters: name, surname, email, phone, membership
  number, national ID, date of birth. You choose which of these an election
  actually uses.
- On publish, those members are **sent to the Vocdoni SaaS API** to build the
  census upstream. Your Vocdoni provider is a processor for that data; the
  contract with them is yours to have.
- Census members are deleted with their election (`dependent: :destroy`), and
  an election is deleted with its component and its participatory space. Nothing
  in this module expires or anonymises a census on its own — retention is a
  decision you have to make and act on.
- A vote is never linked to a voter, in Decidim or in Vocdoni. The receipt a
  voter keeps is a nullifier: it proves a vote was recorded and reveals nothing
  about its content.

Tell your participants which fields you are collecting and why. The public
election page already names the fields a voter will be asked for.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setting up, running the checks and
the rules that are not negotiable, and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
for how we expect people to treat each other. Security issues go to
[SECURITY.md](SECURITY.md), never to the issue tracker.

English is the source language. Three files carry it, split by subject:

| File | Covers |
|---|---|
| `config/locales/en.yml` | the component, the admin and everything server-rendered |
| `config/locales/en.census.yml` | the census: fields, import, verifications |
| `config/locales/en.vote.yml` | the public election page and the static voting page |

`en.vote.yml` is the one the voting page is *built* from, so a change there
needs `npm run build:vote` and a commit of the result. Translations are welcome
as pull requests.

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE).

The static voting page embeds [Source Sans Pro](https://github.com/adobe-fonts/source-sans),
the type face Decidim itself ships, under the SIL Open Font License 1.1.
