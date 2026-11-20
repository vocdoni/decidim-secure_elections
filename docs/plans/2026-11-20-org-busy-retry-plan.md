# Admin writes wait out a busy SaaS organization (#89)

Base: `origin/main` b892e99. Branch: `89-org-busy-retry`. Class: Bounded.

## Spec

Every election of a Decidim install shares one SaaS organization. The SaaS takes one organization
transaction at a time: a write waits up to 10 s for the org lock, then answers 503 with code 50303
(`another transaction for this organization is in progress`), before creating any job. DO App
Platform can turn that 503 into an HTML 504 with no JSON body. Votes never take that lock (they go
through the SaaS relay queue) and are out of scope.

When the work is done:

1. **Busy is recognised.** `ApiError#busy?` is true for code 50303, and for a 503 or 504 whose body
   carried no JSON error code (the DO rewrite). `ApiError#retry_after` holds the `Retry-After`
   response header in seconds (integer or HTTP date), nil when absent.
2. **Busy is a wait, not a failure.** The server-side admin writes (publish steps that write, end
   on chain, question enable voting / publish results) answer a busy error by rescheduling
   themselves: 2 s, 4 s, 8 s, then every 15 s, each with ±20 % jitter, never sooner than
   `retry_after`, for up to 15 minutes from the first busy answer of that action. While waiting
   they do not change the process state, do not write `last_error`, do not record a question
   failure, and do not consume the existing `retry_on` attempts or `CLOSE_ATTEMPTS`.
3. **Pending is visible.** While an action waits, `metadata["pending_actions"][<key>]` holds
   `{since, attempts, at}` (keys: `publish`, `end`, `question_<id>_enable_voting`,
   `question_<id>_publish_results`); it is removed when the action lands. After 15 minutes the
   entry gets `gave_up: true` and stays until the action lands. The admin dashboard renders each
   entry: "waiting for another operation of the organization on the voting network, retrying
   automatically (since HH:MM, N attempts)", and for `gave_up` "not applied after 15 minutes;
   Decidim keeps retrying every few minutes". en/ca/es.
4. **No post-publish job marks the process failed (#84).** `EndProcessOnChainJob`,
   `SyncElectionResultsJob` and `SyncResultsAfterVoteJob` record errors with `keep_state: true`,
   so a transient retry still finds the process `published`.
5. **Divergence converges.** On each run of a published process, `SyncProcessJob` compares what
   Decidim wants with the chain and enqueues the missing move: election ended in Decidim but some
   question still not ENDED/RESULTS/CANCELED on chain → `EndProcessOnChainJob`; a per-question
   question with `voting_enabled_at` set but not open on chain → `enable_voting`; with
   `published_results_at` set but not ENDED/RESULTS → `publish_results`. It skips an action whose
   pending entry is live (not `gave_up`, `at` within the last 2 minutes), so it does not stack
   duplicates on the busy loop. The sync keeps polling while such a divergence exists.
6. **Nothing else changes.** Retry and dedupe paths that exist today (publish `ensure_*` steps,
   `wait_for_publish`, `retry_close`, billing failures, the publish Retry button) behave as before
   for non-busy errors. The busy retries go through the same calls that `retry_on` already retries
   as transient, so they add no new duplicate-write risk.

Out of scope: one SaaS organization per Decidim organization; dashboard auto-refresh.

## Global constraints

- Ruby style of the repo (rubocop config in the repo); comments 1-3 lines, say what and why, no
  history ("was", "previously", "now").
- Conventional commits, no AI attribution or `Co-Authored-By` trailer. Commit with explicit paths.
  Never push.
- Never run bundle/rspec/rubocop on this laptop: tests run in CI on the PR.
- Specs with WebMock, following the existing job specs and `spec/fixtures/vocdoni/`. Cover: busy
  detection (50303 JSON, HTML 504, JSON 503 with another code is not busy), `retry_after` parsing,
  each job's busy path (reschedule delay with jitter bounds, state unchanged, no `last_error`,
  pending entry written, `gave_up` after the window, entry cleared on success), #84 keep_state,
  each reconciler rule and its live-pending skip, the dashboard partial.

## Review focus

- `PublishElectionJob` sets `state: "publishing"` and returns early `if process.publishing?`: a
  busy reschedule must not be dropped by that guard, and must not leave the process stuck in
  `publishing` if the window runs out.
- Jitter and `retry_after` never yield a delay below 1 s; the 15-minute window is measured from
  the first busy answer and carried through the job arguments.
- `record_pending_action!` / `clear_pending_action!` use `with_lock` like
  `record_question_failure!`, so concurrent jobs do not overwrite each other's metadata.
- Reconciler never enqueues for a process that is not published, and never for an election that
  Decidim has not ended / a question Decidim has not moved.

## Tasks

1. `ApiError#busy?`, `#retry_after`; ApiClient reads `Retry-After` on error responses. Specs.
2. `Process#pending_actions`, `#record_pending_action!`, `#clear_pending_action!`; a job concern
   with the busy schedule and the reschedule helper. Specs.
3. Wire the busy path into `EndProcessOnChainJob`, `UpdateQuestionOnChainJob`,
   `PublishElectionJob`; `keep_state: true` in the three post-publish jobs (#84). Specs.
4. Reconciler in `SyncProcessJob`. Specs.
5. Dashboard partial `_pending_actions` + i18n en/ca/es. View spec.
