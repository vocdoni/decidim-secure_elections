# stg3 spike — Start-triggered push to Vochain

_Branch: `spike/integration-into-elections_v3` (from `spike/integration-into-elections_v2`).
Author: 2026-09-17._

Shifts the moment the Vocdoni tx is submitted from **Publish** to **Start**, so
that the on-chain election is created at the same instant Decidim itself
freezes the election. The Publish path becomes a no-op at the Vocdoni layer
for elections opted in to Vocdoni security.

## Motivation

Decidim's editability contract distinguishes Publish from Start:

- **Post-Publish, pre-Start** — the admin can still edit questions, change
  census source, flip start mode, and even change results availability. On a
  scheduled election, the same window is open until `start_at`.
- **Post-Start** — the election is frozen: questions, title, census source
  are immutable; only description remains editable.

Today the module pushes to Vochain at Publish. Any admin edit between Publish
and Start therefore diverges from what Vochain sees, which is why the current
flow effectively requires "publish immediately before starting" — a UX
constraint we imposed, not one Decidim demands.

Aligning the push with Decidim's own freeze point resolves the divergence and
recovers the full editability window Decidim already provides.

## Idea in one line

Move the eight-endpoint push flow from the Publish subscriber to a job
triggered when the election transitions into "started" state, whether via
manual click or scheduled `start_at`.

## Design decisions

### Trigger — command subscriber, not AR callback

Manual start goes through `Decidim::Elections::Admin::UpdateElectionStatus.call(:start, election)`.
The subscriber listens to a Rails Notification emitted by that command
(see "Upstream change" below) and filters on `action == :start`. This
mirrors the existing wiring for `PublishElection` from
[`vocdoni/decidim` PR #2](https://github.com/vocdoni/decidim/pull/2).

Not using an `after_update` callback on the model: it would also fire on
unrelated updates that touch `start_at`, and it couples the module to the
model rather than to the admin action.

### Scheduled start — `wait_until`, not a watcher

At Publish time, if the election is scheduled (has a future `start_at` and is
not manual-start), we enqueue the push job with
`PushElectionJob.set(wait_until: election.start_at).perform_later(id, start_at)`.
Sidekiq holds it in the `schedule` sorted set until fire time and dispatches
it exactly at `start_at`.

Precedent: `decidim-blogs/PublishPostJob` is enqueued the same way — on
create with `wait_until: post.published_at` — and Decidim treats that as the
canonical way to publish a scheduled post. If the job does not run, the
post never appears. Same reliability profile as our case, no watcher, no
cron dependency (Decidim has zero cron-like gems in the tree).

### No preroll

The job fires at `start_at` exactly, not `start_at - 30s`. A brief
unavailability window at the top of the election (Vochain tx propagation +
inclusion, typically 5–15s) is preferable to a silent immutability window
before the announced start time. The transient error is visible and
self-heals; a pre-freeze surprise is silent and one-way for the admin.

### Timestamp mutability — self-invalidating job

If the admin changes `start_at` after Publish, the old job in the schedule
zset is stale. Handled analogously to `PublishPostJob`:

```ruby
def perform(election_id, scheduled_start_at = nil)
  return unless bootstrap!(election_id)
  return if process.publishing? || process.published?
  return if scheduled_start_at.present? && election.start_at != scheduled_start_at.to_datetime
  process.update!(state: "publishing")
  push_to_vochain(election)
  process.update!(state: "published")
end
```

An `after_update_commit` on the election model re-enqueues a new
`PushElectionJob` whenever `start_at` changes. The old job wakes up,
compares timestamps, sees it is stale, and returns. No cancellation API
needed.

### Manual + scheduled race

If the admin clicks Start before `start_at`, the subscriber fires first,
sets `vochain_started_at` on the sidecar, and the scheduled job — when it
eventually wakes up — sees the marker and returns.

### Failure

The push job uses Sidekiq default retries (25 attempts, ~21 days,
exponential backoff). If it lands in the dead set, a card in the Security
tab of the election admin surfaces the failure and offers "Retry push".

If Sidekiq is down at fire time the schedule survives in Redis (see
"Reliability"), and the job dispatches when Sidekiq recovers. The election
is visible as "ongoing" in Decidim during the blackout — voters see an
error at the booth and can refresh once the push completes.

## Upstream change required (Stage A)

New PR to `vocdoni/decidim`: **"Add `with_events` to `UpdateElectionStatus`"**,
analogous to [PR #2](https://github.com/vocdoni/decidim/pull/2) for
`PublishElection`.

- Wrap the status update in `with_events(with_transaction: true) do … end`.
- Define `event_arguments` with `{ election:, action: }`.
- Emits `decidim.events.elections.admin.update_election_status:before` and
  `:after` notifications.

One file touched (`app/commands/decidim/elections/admin/update_election_status.rb`).
Must be merged in the fork before Stage C.

## Code changes in secure_elections

New files:

- `app/subscribers/decidim/secure_elections/vocdoni/push_to_vochain_on_start_subscriber.rb`
  — subscribes to `update_election_status:after`, filters `action == :start`,
  enqueues `PushElectionJob.perform_later(id, election.start_at)`.
- `app/subscribers/decidim/secure_elections/vocdoni/schedule_push_on_publish_subscriber.rb`
  — subscribes to `publish_election:after`, and for scheduled + vocdoni
  elections, enqueues `PushElectionJob.set(wait_until: start_at)
  .perform_later(id, start_at)`. Manual-start scheduled elections skip this
  (they wait for the explicit Start click).
- `app/jobs/decidim/secure_elections/vocdoni/push_election_job.rb` — renamed
  from `publish_election_job.rb`, same body (eight-endpoint flow), with the
  self-invalidation preamble.
- `app/models/concerns/decidim/secure_elections/vocdoni/reschedules_push.rb`
  — `after_update_commit` on Election that re-enqueues `PushElectionJob` when
  `start_at` changes.
- No new migration — the existing `state` column on the sidecar Process
  (`pending` / `publishing` / `published` / `failed`) already carries the
  signal needed for manual/scheduled coordination. The idempotency guard
  in `PushElectionJob#perform` is tightened to also short-circuit on
  `state == "publishing"`, not only on `published_upstream?`.

Removed / reduced:

- The publish-time push in `PublishElectionOnPublishSubscriber` becomes a
  no-op for vocdoni elections. Existing local sidecar creation is kept
  for traceability.

## Reliability

Sidekiq persists everything in Redis:

- Enqueued jobs live in `queue:*` lists.
- Scheduled jobs (`wait_until`) live in the `schedule` sorted set until fire
  time, then move to a queue.
- Failed jobs live in the `retry` zset, then dead set after 25 attempts.

The scheduled push job may sit in `schedule` for days on a scheduled
election. Its survival depends on Redis persistence (AOF or RDB). On z4
(checked 2026-09-17): `appendonly no`, `save 3600 1 300 100 60 10000` —
RDB snapshots only, up to one hour of loss for a quiet Redis but in
practice Sidekiq's heartbeat keeps writes flowing so the 60s / 300s
triggers dominate. Acceptable for a throwaway demo deploy; not the
setting you'd pick for prod.

Blackout window if Sidekiq is down at `start_at`:

- Decidim shows the election as "ongoing" (`Election#started?` is lazy:
  `start_at <= Time.current`).
- Vochain does not have the election yet — voters at the booth see an error.
- When Sidekiq recovers, the schedule scanner (default 5s tick) picks up the
  stale scheduled job and dispatches it. Election becomes votable from that
  moment.

Detection of stuck elections: a light periodic check for elections with
`security = vocdoni` where `start_at < now - 5.minutes` and no
`vochain_started_at`. Surfaces in admin, no auto-recovery beyond
"Retry push".

## Deploy topology — stg3 on z4

Third staging deploy, alongside `stg` (Phase-4) and `stg2` (parallel
Phase-4). Cloned from stg2's recipe.

| | stg | stg2 | **stg3** |
|---|---|---|---|
| Port | 3001 | 3002 | **3003** |
| Sidekiq Redis db | 0 | 5 | **7** |
| Cache Redis db | 4 | 6 | **8** |
| DB | `decidim_stg_app_dev` | `decidim_stg2_app_dev` | **`decidim_stg3_app_dev`** |
| Sidekiq queue | `vocdoni_spike` | `vocdoni_spike` | `vocdoni_spike` (same; isolated via Redis db) |
| Tree | `~/decidim/stg/` | `~/decidim/stg2/` | **`~/decidim/stg3/`** |
| Monorepo symlink | — | `→ ../stg/decidim` | **`→ ../stg/decidim`** |
| Tunnel log | `/tmp/cftunnel-stg.log` | `/tmp/cftunnel-stg2.log` | **`/tmp/cftunnel-stg3.log`** |
| Branch | `spike/phase-4-registration` | `spike/phase-4-registration` | **`spike/integration-into-elections_v3`** |

Queue name matches stg/stg2 (`vocdoni_spike`). Isolation is via Redis dbs
7/8, which is sufficient — jobs enqueued by stg3's Rails go into db 7,
picked up only by stg3's sidekiq (which also connects to db 7). Prod's
sidekiq listens on the `vocdoni` queue in Redis db 0, so there is no
cross-listen path.

Bootstrap follows the stg2 recipe verbatim with the deltas above.

## Stages

- **A** — Upstream PR to `vocdoni/decidim`: `UpdateElectionStatus with_events`.
  Must merge in the fork before Stage C. Blocks the rest.
- **B** — Refactor `publish_election_job` → `push_election_job` on
  `spike/integration-into-elections_v3`. Behavior unchanged, tests green.
  No subscriber changes yet.
- **C** — Add `PushToVochainOnStartSubscriber` and the sidecar
  `vochain_started_at` migration. Wire up subscribers. Manual-start
  end-to-end works locally.
- **D** — Add `SchedulePushOnPublishSubscriber` (`wait_until`) and the
  `RechedulesPush` concern (`after_update_commit`). Self-invalidation in
  `PushElectionJob`. Scheduled-start end-to-end works locally.
- **E** — Bring up stg3 on z4. Run the test plan.

## Test plan on stg3

Six cases, all with `security = vocdoni` unless noted:

1. Manual-start, publish → no edits → start. Expected: publish makes zero
   SaaS calls; start fires the eight-endpoint flow; voting works.
2. Manual-start, publish → edit questions → start. Expected: question edits
   are reflected in the on-chain process.
3. Manual-start, publish → change census source → start. Expected: the
   group created at start uses the final census.
4. Scheduled-start, publish with `start_at = now + 2min`. Expected: the
   push job fires at `start_at`; brief booth error (5–15s) then voting
   works.
5. Scheduled-start, publish then reschedule `start_at`. Expected: the old
   scheduled job is self-invalidated when it wakes; a new one, enqueued by
   the model callback, fires at the new time.
6. Scheduled-start, admin clicks Start manually before `start_at`.
   Expected: manual subscriber wins; the scheduled job self-invalidates
   when it wakes.

Regression: a non-vocdoni election in the same deploy behaves identically
to upstream, with zero SaaS calls at either Publish or Start.

## Out of scope

- Changes to `:end` and `:publish_results` (same command, different
  `action`). Deferred to a future spike; the subscriber added in Stage C
  can be extended when we get there.
- Public feature flag. The switch is per-deploy: stg3 runs the new
  behaviour, `stg` and prod keep the current Publish-triggered flow. If
  the spike validates, a follow-up decides how to promote it.

## Fallback if Stage A is rejected upstream

If `UpdateElectionStatus with_events` is not accepted in the fork, Stage C
falls back to an `after_update_commit` on the election model with
`saved_change_to_start_at? && start_at.past?`. Uglier (couples to the
model, fires in more contexts), but functionally equivalent. Stage D is
unaffected — it does not depend on the upstream PR.

## Related

- [`decidim-blogs/PublishPostJob`](https://github.com/decidim/decidim/blob/develop/decidim-blogs/app/jobs/decidim/blogs/publish_post_job.rb)
  — the canonical `wait_until` precedent this spike leans on.
- [`vocdoni/decidim` PR #2](https://github.com/vocdoni/decidim/pull/2) —
  `PublishElection with_events`, the pattern Stage A replicates for
  `UpdateElectionStatus`.
- `docs/phase-4-spike.md` — extension surface this spike builds on.
