# End-to-end checklist

Run before every production release, on the staging deployment that runs the release candidate
(decidim-dev), against the dev SaaS. Specs cover each piece; this checks that Decidim, the booth, the
SaaS and the chain agree.

## Setup

- One participatory space with an elections component reserved for QA; title every election
  "QA ... (ignore)" and delete them afterwards.
- A disposable mailbox (for example mail.tm) for the voter, so one-time codes and the census email
  are real.
- Two QA accounts: an org admin, and a participant with the voter's mailbox as email.
- Two questions per election, so per-question opening and partial ballots are exercised.
- Keep censuses at 25 voters or fewer: they are free and leave the integrator wallet alone.

## Matrix: results availability x census

Run every cell. In each one: vote with both questions answered, check both receipts in the booth,
then check results as described for the row.

| Results \ Census | CSV (`token_csv`) | Dynamic (`internal_users`) |
|---|---|---|
| `real_time` | 1 | 2 |
| `after_end` | 3 | 4 |
| `per_question` | 5 | 6 |

- **Census, CSV**: the voter enters email + token at "Verify your identity"; a wrong token stays on
  the form.
- **Census, dynamic**: the voter signs in; with an authorization handler set, a participant without
  it gets the verification page instead of the booth. Set the handlers through the admin Census tab
  (stored as `census_settings["authorization_handlers"]`) and pick one registered in production
  mode: the `dummy_*` handlers only exist in development.
- **`real_time`**: the public page shows the tally a few seconds after the vote, with no admin
  action (ballots are not encrypted).
- **`after_end`**: no results while voting; admin ends the election, the chain decrypts, admin
  publishes, the public page shows the tally.
- **`per_question`**: the voter enters before any question is open and waits; admin enables Q1, the
  voter is taken to the booth; after voting Q1 the booth waits; admin publishes Q1 and enables Q2;
  Q2 appears in the booth with no reload; admin publishes Q2; both tallies show.

## Cross-cutting cases

- **Email one-time code** (Security tab, Email on), once per census type: the code arrives, a wrong
  code is rejected with a message, the right one opens the ballot.
- **Second visit**: entering again after voting shows the receipts, not a new ballot.
- **Explorer**: the election page and dashboard link every question to the explorer.
- **Publish failure**: with a spend cap below the census cost (or an integrator with an empty
  wallet), the dashboard shows the billing alert: the org admin gets the platform link, a space
  admin the "ask an admin" text. Lifting the cap and clicking Retry publishes.
- **Browser console**: no errors other than the SaaS 401 for a wrong one-time code.

## Cleanup

End on chain every QA election still running, soft-delete the elections and the QA accounts, and
restore any swapped SaaS credentials and spend cap.
