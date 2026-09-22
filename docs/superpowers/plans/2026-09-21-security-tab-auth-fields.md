# Security-tab auth fields — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let admins pick the Vocdoni CSP `authFields` on the Security tab (only when the secret vote is selected) — five checkboxes cherry-picking PR #28's visual set, wired to the existing sidecar-settings pipeline.

**Architecture:** New card between choice and 2FA, same fieldset+`disabled` pattern as `_two_factor.html.erb`. Form gains an `auth_fields` array attribute; the command persists it under `sidecar.metadata["settings"]["auth_fields"]`; the publish job reads it (fallback `["memberNumber"]`).

**Tech Stack:** Ruby / Rails 7, Decidim engine, RSpec.

## Global Constraints

- **Allowlist (verbatim from `saas-backend/db/types.go:358-362`)**: `memberNumber`, `nationalId`, `name`, `surname`, `birthDate`. Anything else is rejected server-side.
- **Default when unspecified**: `["memberNumber"]` (matches today's hardcoded behavior; keeps existing sidecars working).
- **At least one box must be checked** when Vocdoni is enabled.
- **Security level pill is unchanged** — identity fields do not affect the `basic / strong / strongest` summary.
- **JS is enhancement-only** — server renders every state.
- **Copy in English** in the locale file. All keys under `decidim.elections.vocdoni.admin.security.show.auth_fields`.
- **Selectors: `js-`-prefixed ids and `data-*` attributes; never classes.**
- **PRs/commits in English** (per user preference).

---

### Task 1: Extend `SecurityForm` with `auth_fields`

**Files:**
- Modify: `app/forms/decidim/elections/vocdoni/admin_forms/security_form.rb`
- Modify: `spec/forms/decidim/elections/vocdoni/admin_forms/security_form_spec.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: `SecurityForm#auth_fields → Array<String>` (validated allowlist, sorted, defaults to `["memberNumber"]` when the fieldset is disabled or nothing survives filtering); constant `SecurityForm::AUTH_FIELD_OPTIONS = %w(memberNumber nationalId name surname birthDate).freeze`.

- [ ] **Step 1: Add failing form specs**

Append these context blocks inside `describe SecurityForm do` (before the closing `end`), keeping the existing tests untouched:

```ruby
describe "#auth_fields" do
  context "when the fieldset is disabled (simple vote)" do
    subject(:form) { described_class.from_params(security: { enable_vocdoni: "false", auth_fields: [""] }) }

    it "collapses to the default" do
      expect(form.auth_fields).to eq(%w(memberNumber))
    end
  end

  context "when the admin picks two fields" do
    subject(:form) { described_class.from_params(security: { enable_vocdoni: "true", auth_fields: ["", "nationalId", "memberNumber"] }) }

    it "returns the allowlisted picks, sorted" do
      expect(form.auth_fields).to eq(%w(memberNumber nationalId))
    end

    it "is valid" do
      expect(form).to be_valid
    end
  end

  context "when the admin unchecks every box" do
    subject(:form) { described_class.from_params(security: { enable_vocdoni: "true", auth_fields: [""] }) }

    it "is invalid" do
      expect(form).not_to be_valid
      expect(form.errors[:auth_fields]).to be_present
    end
  end

  context "when the params contain a field the SaaS rejects" do
    subject(:form) { described_class.from_params(security: { enable_vocdoni: "true", auth_fields: ["", "memberNumber", "email"] }) }

    it "is invalid" do
      expect(form).not_to be_valid
      expect(form.errors[:auth_fields]).to be_present
    end
  end

  context "when reading a sidecar that predates this feature" do
    before { Vocdoni::Process.create!(election:, state: "pending") }

    subject(:form) { described_class.from_model(election) }

    it "defaults to memberNumber" do
      expect(form.auth_fields).to eq(%w(memberNumber))
    end
  end

  context "when reading a sidecar that stored auth_fields" do
    before do
      Vocdoni::Process.create!(election:, state: "pending",
                               metadata: { "settings" => { "auth_fields" => %w(nationalId memberNumber) } })
    end

    subject(:form) { described_class.from_model(election) }

    it "reads them back, sorted" do
      expect(form.auth_fields).to eq(%w(memberNumber nationalId))
    end
  end
end
```

- [ ] **Step 2: Run the new specs to see them fail**

```
bundle exec rspec spec/forms/decidim/elections/vocdoni/admin_forms/security_form_spec.rb -e "#auth_fields"
```

Expected: 6 failures, all about `auth_fields` not being defined / not filtered.

- [ ] **Step 3: Implement the attribute + validation + accessor**

In `security_form.rb`, add — beside the existing declarations — a class-level allowlist, a nullable Array attribute, the two validations, and a public accessor that filters/sorts. Also extend `from_model` to read the sidecar key. Full file after the change:

```ruby
# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module AdminForms
        # Security tab form. Owns three things:
        #
        #   1. Whether the election opts in to Vocdoni-backed secure voting
        #      (`enable_vocdoni`). Opt-in is materialised as the presence of
        #      the {Process} sidecar row.
        #
        #   2. The identity fields the CSP checks against the memberbase
        #      (`auth_fields`). One-of / many-of choice over the SaaS's five
        #      allowed authFields. Defaults to `["memberNumber"]`.
        #
        #   3. The second-factor challenge for CSP authentication. Two
        #      independent booleans — SMS and Email — that map onto the
        #      Vocdoni SaaS `twoFaFields` array (`"phone"` and `"email"`
        #      respectively). All four combinations are valid:
        #
        #        [] []  → no OTP (weakest, only CSP identity)
        #        [x] [] → SMS OTP only
        #        [] [x] → Email OTP only
        #        [x] [x] → voter picks at auth time (SaaS OR)
        #
        # Persisted through {Admin::UpdateElectionSecurity} onto the sidecar's
        # `metadata["settings"]` hash. The engine's publish subscriber checks
        # `election.vocdoni_process.present?` to decide whether to enqueue
        # {PublishElectionJob}.
        class SecurityForm < Decidim::Form
          mimic :security

          # Exactly the values `saas-backend/db/types.go:358-362` accepts as
          # OrgMemberAuthFields. Order = the order the checkboxes render.
          AUTH_FIELD_OPTIONS = %w(memberNumber nationalId name surname birthDate).freeze
          DEFAULT_AUTH_FIELDS = %w(memberNumber).freeze

          attribute :enable_vocdoni, Boolean, default: false
          attribute :sms, Boolean, default: false
          attribute :email, Boolean, default: false
          attribute :auth_fields, Array[String], default: -> { [] } # rubocop:disable Style/RedundantArrayConstructor -- Decidim attribute type

          validate :auth_fields_allowed, if: :enable_vocdoni
          validate :auth_fields_present, if: :enable_vocdoni

          # Reconstructs a form from the sidecar. An election that has never
          # visited the Security tab has no sidecar; every checkbox defaults
          # to unchecked and the identity picker to `["memberNumber"]`.
          def self.from_model(election)
            sidecar = election.vocdoni_process
            return new if sidecar.blank?

            settings = sidecar.metadata.to_h["settings"].to_h
            two_fa = Array(settings["twofa_fields"]).map(&:to_s)
            stored = Array(settings["auth_fields"]).map(&:to_s)
            new(enable_vocdoni: true,
                sms: two_fa.include?("phone"),
                email: two_fa.include?("email"),
                auth_fields: stored)
          end

          # Summary levels shown on the tab, from least to most protected.
          # Identity picks do not affect this — a code is what proves
          # liveness, not the identifier.
          LEVELS = %w(basic strong strongest).freeze

          # The page presents `enable_vocdoni` as two cards: a simple vote
          # (off) and a secret, verifiable vote (on).
          def choice
            enable_vocdoni ? "secure" : "simple"
          end

          def level
            return "basic" unless enable_vocdoni

            two_fa_fields.any? ? "strongest" : "strong"
          end

          # SaaS-shape array — the same value we forward verbatim as
          # `twoFaFields` in the process-creation payload. Kept sorted so
          # two equivalent selections do not appear as different diffs.
          def two_fa_fields
            fields = []
            fields << "email" if email
            fields << "phone" if sms
            fields.sort
          end

          # Overrides the raw attribute so views, the command, and the
          # publish job all see the same filtered/sorted list. Callers can
          # still assign the raw array; reads always normalize.
          def auth_fields
            picked = Array(super).map(&:to_s).compact_blank & AUTH_FIELD_OPTIONS
            return DEFAULT_AUTH_FIELDS.dup unless enable_vocdoni

            picked.sort
          end

          def auth_field_selected?(field)
            auth_fields.include?(field)
          end

          private

          def auth_fields_present
            errors.add(:auth_fields, :blank) if auth_fields.empty?
          end

          def auth_fields_allowed
            submitted = Array(read_attribute_for_validation(:auth_fields)).map(&:to_s).compact_blank
            refused = submitted - AUTH_FIELD_OPTIONS
            errors.add(:auth_fields, :inclusion) if refused.any?
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Rerun the form specs**

```
bundle exec rspec spec/forms/decidim/elections/vocdoni/admin_forms/security_form_spec.rb
```

Expected: all pass (existing 2FA specs stay green, six new ones pass).

- [ ] **Step 5: Commit**

```
git add app/forms/decidim/elections/vocdoni/admin_forms/security_form.rb \
        spec/forms/decidim/elections/vocdoni/admin_forms/security_form_spec.rb
git commit -m "Security form: add auth_fields attribute with allowlist"
```

---

### Task 2: Persist `auth_fields` on the sidecar

**Files:**
- Modify: `app/commands/decidim/elections/vocdoni/admin/update_election_security.rb`
- Modify: `spec/commands/decidim/elections/vocdoni/admin/update_election_security_spec.rb`

**Interfaces:**
- Consumes: `SecurityForm#auth_fields` from Task 1.
- Produces: `sidecar.metadata["settings"]["auth_fields"]` — verbatim `SecurityForm#auth_fields`.

- [ ] **Step 1: Add failing command spec**

Read the existing spec first to match its style, then append a context inside `describe UpdateElectionSecurity do`:

```ruby
context "when the form picks auth_fields" do
  let(:form) do
    Decidim::Elections::Vocdoni::AdminForms::SecurityForm.from_params(
      security: { enable_vocdoni: "true", email: "1", auth_fields: ["", "nationalId", "memberNumber"] }
    )
  end

  it "persists them on the sidecar" do
    described_class.new(form, election).call
    settings = election.reload.vocdoni_process.metadata.to_h["settings"].to_h
    expect(settings["auth_fields"]).to eq(%w(memberNumber nationalId))
    expect(settings["twofa_fields"]).to eq(%w(email))
  end
end
```

- [ ] **Step 2: Run the spec — it should fail**

```
bundle exec rspec spec/commands/decidim/elections/vocdoni/admin/update_election_security_spec.rb
```

Expected: 1 failure (settings has no `auth_fields` key).

- [ ] **Step 3: Update the command**

In `update_election_security.rb`, extend `enable!` to write both keys:

```ruby
def enable!
  sidecar = election.vocdoni_process || Process.new(decidim_election_id: election.id, state: "pending")
  sidecar.metadata = sidecar.metadata.to_h.merge(
    "settings" => {
      "twofa_fields" => form.two_fa_fields,
      "auth_fields" => form.auth_fields
    }
  )
  sidecar.save!
end
```

- [ ] **Step 4: Rerun the spec**

```
bundle exec rspec spec/commands/decidim/elections/vocdoni/admin/update_election_security_spec.rb
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
git add app/commands/decidim/elections/vocdoni/admin/update_election_security.rb \
        spec/commands/decidim/elections/vocdoni/admin/update_election_security_spec.rb
git commit -m "UpdateElectionSecurity: persist auth_fields on sidecar settings"
```

---

### Task 3: Publish job reads `authFields` from the sidecar

**Files:**
- Modify: `app/jobs/decidim/elections/vocdoni/publish_election_job.rb:466-472`
- Create: `spec/jobs/decidim/elections/vocdoni/publish_election_job_auth_fields_spec.rb`

**Interfaces:**
- Consumes: sidecar `metadata["settings"]["auth_fields"]` from Task 2.
- Produces: `census["authFields"]` in the process payload matches the sidecar; defaults to `["memberNumber"]` when the sidecar has no key.

- [ ] **Step 1: Add failing spec**

Create `spec/jobs/decidim/elections/vocdoni/publish_election_job_auth_fields_spec.rb`:

```ruby
# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Vocdoni
      describe PublishElectionJob do
        let(:election) { create(:election) }

        def auth_fields_of(sidecar_settings)
          Vocdoni::Process.create!(election:, state: "pending", metadata: { "settings" => sidecar_settings })
          described_class.new.tap { |job| job.instance_variable_set(:@election, election) }.send(:auth_fields)
        end

        it "reads the sidecar-stored fields" do
          expect(auth_fields_of("auth_fields" => %w(nationalId memberNumber))).to eq(%w(nationalId memberNumber))
        end

        it "falls back to memberNumber when the key is absent" do
          expect(auth_fields_of("twofa_fields" => %w(email))).to eq(%w(memberNumber))
        end

        it "falls back to memberNumber when the value is blank" do
          expect(auth_fields_of("auth_fields" => [])).to eq(%w(memberNumber))
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run to confirm failures**

```
bundle exec rspec spec/jobs/decidim/elections/vocdoni/publish_election_job_auth_fields_spec.rb
```

Expected: two failures (fields case returns `["memberNumber"]`, everything else passes) OR — depending on how `@election` is memoized — three failures.

- [ ] **Step 3: Rework `auth_fields` in the job**

Replace lines 466–472 in `publish_election_job.rb`:

```ruby
        # Identity fields the CSP checks against the memberbase, chosen on
        # the Security tab. Verbatim to `authFields` in the process payload.
        # A sidecar without the key (predates the picker) falls back to
        # `memberNumber`, keeping every existing election working.
        def auth_fields
          stored = Array(process.metadata.to_h.dig("settings", "auth_fields")).map(&:to_s).compact_blank
          stored.presence || %w(memberNumber)
        end
```

- [ ] **Step 4: Rerun spec — should pass**

```
bundle exec rspec spec/jobs/decidim/elections/vocdoni/publish_election_job_auth_fields_spec.rb
```

Expected: 3 pass.

- [ ] **Step 5: Commit**

```
git add app/jobs/decidim/elections/vocdoni/publish_election_job.rb \
        spec/jobs/decidim/elections/vocdoni/publish_election_job_auth_fields_spec.rb
git commit -m "PublishElectionJob: read authFields from sidecar (fallback memberNumber)"
```

---

### Task 4: Render the auth-fields card + copy

**Files:**
- Create: `app/views/decidim/elections/vocdoni/admin/security/_auth_fields.html.erb`
- Modify: `app/views/decidim/elections/vocdoni/admin/security/show.html.erb`
- Modify: `lib/decidim/elections/vocdoni/phase_4_spike/config/locales/en.yml`

**Interfaces:**
- Consumes: `SecurityForm#auth_fields`, `#auth_field_selected?`, `AUTH_FIELD_OPTIONS`.
- Produces: DOM node `<fieldset id="js-security-auth-fields" ...>` for Task 5's JS.

- [ ] **Step 1: Add the copy**

First, locate the existing 2FA copy so the new keys sit next to it:

```
rtk grep -n "two_factor:" lib/decidim/elections/vocdoni/phase_4_spike/config/locales/en.yml
```

Then, in the same `show:` block (right below `two_factor:`), add:

```yaml
              auth_fields:
                legend: "Who the voter says they are"
                lead: "The service checks these against the members you push. Pick one or more; every voter must have all of them."
                simple_note: "A simple Decidim vote does not ask for any of these."
                error: "Pick at least one identifier the voters have."
                options:
                  memberNumber:
                    label: "Member number"
                    help: "Unique to each person. What we push for every Decidim user today."
                  nationalId:
                    label: "National ID number"
                    help: "Unique to each person. Requires the ID column on your roster."
                  name:
                    label: "First name"
                    help: "Not unique on its own — combine with another field."
                  surname:
                    label: "Last name"
                    help: "Not unique on its own — combine with another field."
                  birthDate:
                    label: "Date of birth"
                    help: "Rarely unique. Combine with a name."
```

Also add the RSpec validation-message key under the top-level `errors:` block if one exists in this file, or fall back to the built-in `blank` message (already used by other Vocdoni forms).

- [ ] **Step 2: Create the partial**

`app/views/decidim/elections/vocdoni/admin/security/_auth_fields.html.erb`:

```erb
<%#
  Card 3: who the voter says they are (`authFields`).

  Only meaningful for a secret vote, so the whole fieldset is `disabled`
  while the simple vote is selected; `security.js` flips it as the admin
  changes the vote type. The five checkboxes are exactly the SaaS's
  allowlist (`saas-backend/db/types.go:358-362`).
%>
<% scope = "decidim.elections.vocdoni.admin.security.show.auth_fields" %>
<% enabled = @form.enable_vocdoni %>
<% options = Decidim::Elections::Vocdoni::AdminForms::SecurityForm::AUTH_FIELD_OPTIONS %>
<div class="card vocdoni-security__card">
  <div class="card-divider">
    <h2 class="card-title" id="security-auth-fields-title"><%= t("legend", scope:) %></h2>
  </div>

  <div class="card-section">
    <div class="row column">
      <fieldset id="js-security-auth-fields"
                class="vocdoni-security__fieldset vocdoni-auth-fields"
                aria-labelledby="security-auth-fields-title"
                aria-describedby="security-auth-fields-lead"
                <%= "disabled" unless enabled %>>
        <p class="vocdoni-security__lead" id="security-auth-fields-lead"><%= t("lead", scope:) %></p>

        <p class="vocdoni-security__note" data-auth-fields-note="simple" <%= "hidden" if enabled %>>
          <%= icon "information-line" %>
          <span><%= t("simple_note", scope:) %></span>
        </p>

        <%# Empty hidden field so an all-unchecked submit still reaches the server. %>
        <input type="hidden" name="security[auth_fields][]" value="">
        <ul class="vocdoni-auth-fields__list">
          <% options.each do |field| %>
            <li class="vocdoni-auth-fields__item">
              <label class="vocdoni-auth-fields__label" for="security_auth_fields_<%= field %>">
                <input type="checkbox"
                       name="security[auth_fields][]"
                       id="security_auth_fields_<%= field %>"
                       value="<%= field %>"
                       data-auth-field
                       aria-describedby="security-auth-fields-<%= field %>-help"
                       <%= "checked" if @form.auth_field_selected?(field) %>>
                <span><%= t("options.#{field}.label", scope:) %></span>
              </label>
              <p class="help-text vocdoni-auth-fields__help" id="security-auth-fields-<%= field %>-help">
                <%= t("options.#{field}.help", scope:) %>
              </p>
            </li>
          <% end %>
        </ul>

        <% if @form.errors[:auth_fields].any? %>
          <p class="form-error is-visible" role="alert"><%= @form.errors[:auth_fields].to_sentence %></p>
        <% end %>
      </fieldset>
    </div>
  </div>
</div>
```

- [ ] **Step 3: Wire the partial into `show.html.erb`**

Between the choice card and the two_factor card, add the render:

```erb
    <%= render "decidim/elections/vocdoni/admin/security/choice", f: %>
    <%= render "decidim/elections/vocdoni/admin/security/auth_fields", f: %>
    <%= render "decidim/elections/vocdoni/admin/security/two_factor", f: %>
```

- [ ] **Step 4: Manual sanity — the app boots and the tab renders**

```
bundle exec rails runner 'puts Decidim::Elections::Vocdoni::AdminForms::SecurityForm::AUTH_FIELD_OPTIONS.inspect'
```

Expected: `["memberNumber", "nationalId", "name", "surname", "birthDate"]`.

- [ ] **Step 5: Commit**

```
git add app/views/decidim/elections/vocdoni/admin/security/_auth_fields.html.erb \
        app/views/decidim/elections/vocdoni/admin/security/show.html.erb \
        lib/decidim/elections/vocdoni/phase_4_spike/config/locales/en.yml
git commit -m "Security tab: render auth-fields card (Vocdoni-only)"
```

---

### Task 5: Disable the auth-fields fieldset when Simple vote is chosen

**Files:**
- Modify: `app/packs/src/decidim/elections/vocdoni/admin/security.js`

**Interfaces:**
- Consumes: `#js-security-auth-fields` from Task 4.
- Produces: fieldset `disabled` flips in step with the vote-type radios; `data-auth-fields-note="simple"` follows the same convention as `data-two-factor-note`.

- [ ] **Step 1: Extend the JS**

Add the constant, look it up in `setupSecurity`, and mirror the two_factor sync:

```javascript
const AUTH_FIELDS_ID = "js-security-auth-fields";
```

Inside `setupSecurity`, after `const twoFactor = ...`:

```javascript
const authFields = document.getElementById(AUTH_FIELDS_ID);
```

Inside the same body, after `const notes = Array.from(twoFactor.querySelectorAll("[data-two-factor-note]"));`:

```javascript
const authNotes = authFields
  ? Array.from(authFields.querySelectorAll("[data-auth-fields-note]"))
  : [];
```

Add a new sync helper next to `syncTwoFactor`:

```javascript
const syncAuthFields = (value) => {
  if (!authFields) {
    return;
  }
  const usable = value === "secure";
  authFields.disabled = !usable;
  authNotes.forEach((element) => {
    element.hidden = usable;
  });
};
```

Call it from `sync`:

```javascript
const sync = () => {
  const value = selected();
  syncCards(value);
  syncAuthFields(value);
  syncSummary(securityLevel(value, syncTwoFactor(value)));
};
```

- [ ] **Step 2: Lint the file**

```
npx eslint app/packs/src/decidim/elections/vocdoni/admin/security.js
```

Expected: 0 errors.

- [ ] **Step 3: Commit**

```
git add app/packs/src/decidim/elections/vocdoni/admin/security.js
git commit -m "Security tab JS: disable auth-fields fieldset on simple vote"
```

---

### Task 6: Full sweep — lints + rspec + copy check

**Files:** none new. Verifies the branch as a whole.

- [ ] **Step 1: RSpec on everything we touched**

```
bundle exec rspec spec/forms/decidim/elections/vocdoni/admin_forms/security_form_spec.rb \
                  spec/commands/decidim/elections/vocdoni/admin/update_election_security_spec.rb \
                  spec/jobs/decidim/elections/vocdoni/publish_election_job_auth_fields_spec.rb
```

Expected: all pass.

- [ ] **Step 2: Rubocop on modified Ruby files**

```
bundle exec rubocop app/forms/decidim/elections/vocdoni/admin_forms/security_form.rb \
                    app/commands/decidim/elections/vocdoni/admin/update_election_security.rb \
                    app/jobs/decidim/elections/vocdoni/publish_election_job.rb \
                    spec/forms/decidim/elections/vocdoni/admin_forms/security_form_spec.rb \
                    spec/commands/decidim/elections/vocdoni/admin/update_election_security_spec.rb \
                    spec/jobs/decidim/elections/vocdoni/publish_election_job_auth_fields_spec.rb
```

Expected: 0 offenses.

- [ ] **Step 3: ERB lint (if configured)**

```
bundle exec erb_lint --lint-all --format compact 2>/dev/null || true
```

- [ ] **Step 4: JS lint on everything under the admin dir**

```
npx eslint app/packs/src/decidim/elections/vocdoni/admin/security.js
```

- [ ] **Step 5: Whole suite (or as much as CI runs)**

```
bundle exec rspec
```

Note: 15 pre-existing failures (per PR #28 body). Confirm no *new* failures.

- [ ] **Step 6: Push + open PR against fresh main**

```
git push -u origin worktree-security-auth-fields
gh pr create --base main --title "Security tab: pick auth fields (Vocdoni only)" \
             --body "$(cat docs/superpowers/plans/2026-09-21-security-tab-auth-fields.md ...)"
```

(Use the actual PR body — a short summary drawn from the spec, plus the test plan, per the repo's PR conventions.)

---

## Self-Review

**Spec coverage:** every bullet in the spec maps to a task —
- Card + placement → Task 4.
- `SecurityForm.auth_fields` attribute + allowlist + default → Task 1.
- Sidecar `settings.auth_fields` persistence → Task 2.
- Publish job reads from sidecar → Task 3.
- JS disable-on-simple → Task 5.
- Copy → Task 4.
- Specs (form, command, job) → Tasks 1, 2, 3.

**Placeholders:** none — every step has runnable code / commands.

**Type consistency:** `AUTH_FIELD_OPTIONS`, `DEFAULT_AUTH_FIELDS`, `auth_fields`, `auth_field_selected?` used in Task 4 all defined in Task 1. Sidecar key `auth_fields` written in Task 2, read in Task 1 (`from_model`) and Task 3 (job).
