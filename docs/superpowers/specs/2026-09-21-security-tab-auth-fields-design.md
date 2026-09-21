# Security tab: pick auth fields (Vocdoni only)

## What this changes

The Security tab has a card for the one-time code (2FA: email / SMS). It has
no card for **who the voter says they are** — the identity part of CSP auth is
hardcoded to `["memberNumber"]` in `PublishElectionJob#auth_fields`
(`app/jobs/decidim/elections/vocdoni/publish_election_job.rb:470-472`).

This adds a new card between the choice card and the 2FA card. Same fieldset
pattern as 2FA: only enabled when the secret vote is selected, disabled and
noted otherwise. Five checkboxes — the five fields the SaaS accepts as
`authFields` (verified in `saas-backend/db/types.go:358-362`):

| Field          | Default checked |
|----------------|-----------------|
| `memberNumber` | yes             |
| `nationalId`   | no              |
| `name`         | no              |
| `surname`      | no              |
| `birthDate`    | no              |

The choices are stored on the same sidecar hash that already carries the 2FA
selection and forwarded verbatim to the SaaS on publish.

## What this deliberately does not do

Everything PR #28 built around identifiers is scoped to the Census tab, where
CSV columns exist. The Security tab has no columns to derive from. So this
spec **skips**:

- deriving a default from anything (five static defaults; user overrides them)
- the `chosen_identifiers` / `derived_identifiers` machinery from #28
- badges (`sends_code`, `simple_only`), weak-identifier warnings
- details/summary "Change" disclosure — the list is the card
- the `ChoosesIdentifiers` concern + `CensusCsv::Fields` module
- validation beyond "at least one box checked"
- affecting the resulting security level pill (identity fields do not change
  liveness — the pill still reflects only `enable_vocdoni` + 2FA)

If PR #28 later lands and moves the picker to the Census tab, this Security
card is trivial to remove — it is a single partial + a form attribute + one
sidecar key.

## Files touched

**New:**
- `app/views/decidim/elections/vocdoni/admin/security/_auth_fields.html.erb`
  — the card, cloned from `_two_factor.html.erb`'s structure.
- `spec/forms/decidim/elections/vocdoni/admin_forms/security_form_spec.rb`
  additions (or a new spec) covering the new attribute.

**Modified:**
- `app/forms/decidim/elections/vocdoni/admin_forms/security_form.rb`
  — new `auth_fields` attribute (Array[String]), allowlist validation,
  `from_model` reads it back from the sidecar.
- `app/commands/decidim/elections/vocdoni/admin/update_election_security.rb`
  — writes `settings.auth_fields` alongside `settings.twofa_fields`.
- `app/jobs/decidim/elections/vocdoni/publish_election_job.rb`
  — `auth_fields` reads from sidecar; fallback `["memberNumber"]`.
- `app/views/decidim/elections/vocdoni/admin/security/show.html.erb`
  — renders the new partial between choice and two_factor.
- `app/packs/src/decidim/elections/vocdoni/admin/security.js`
  — new fieldset id in the disable-on-simple list.
- `lib/decidim/elections/vocdoni/phase_4_spike/config/locales/en.yml`
  — copy for the new card (legend, lead, per-field label + help, simple_note,
  validation error).
- specs for update command + publish job (identity payload now variable).

Small enough to review in one commit. Style follows the two_factor card
verbatim: `<fieldset id="js-security-auth-fields" ... disabled ...>` with a
`data-two-factor-note="simple"` twin for the disabled explainer, `data-*`
hooks (never classes) for the JS.

## Data flow

```
SecurityForm { enable_vocdoni, sms, email, auth_fields[] }
      │
      ▼ UpdateElectionSecurity
sidecar.metadata["settings"] = {
  "twofa_fields" => [...],
  "auth_fields"  => [...]        ← NEW
}
      │
      ▼ PublishElectionJob#auth_fields
{
  "census" => {
    "authFields" => auth_fields,  ← read from sidecar (was hardcoded)
    "twoFaFields" => two_fa_fields,
    "groupId" => ...
  }
}
```

Default when the sidecar has no `auth_fields` key (existing sidecars from
before this change): `["memberNumber"]`. Same effective behavior as today.

## Validation

Server-side, on the form:

- Each submitted value must be in the five-field allowlist.
- At least one box must be checked (mimics the SaaS's "authFields required"
  rule; empty auth is a separate mode we do not surface here).

No client-side gating. `security.js` toggles the fieldset's `disabled`
attribute in sync with the vote-type radios; nothing else.

## Testing

- Form spec: default (`["memberNumber"]`), roundtrip via `from_model`,
  allowlist rejection, "at least one" error.
- Command spec: writes `settings.auth_fields` on enable; leaves it alone on
  disable (destroy path unchanged).
- Publish-job census-payload spec: `authFields` reflects the sidecar; fallback
  to `["memberNumber"]` when key absent.
- Existing 2FA specs stay green (orthogonal change).
- Manual: check the tab in the browser on the dev app, publish an election
  with a non-default choice (e.g. `memberNumber + nationalId`), confirm the
  process on the SaaS carries the same `authFields`.

## Out of scope / follow-ups

- Roster columns: today `user_to_member` only sends `memberNumber, name,
  email`. Picking `nationalId`, `surname`, or `birthDate` would validate on
  the Security tab but produce a member index without those fields, and the
  process publish would then fail on the SaaS side. This is a separate
  change (adding roster columns and their source in Decidim). This spec does
  not touch the roster.
- Warning banner on the Security tab for "you picked fields your roster does
  not carry" — nice, but requires roster introspection. Defer.
- Aligning with PR #28's Census-tab identifier UI once #28 lands: the two
  can coexist temporarily; #28's version would win and this card could be
  retired.
