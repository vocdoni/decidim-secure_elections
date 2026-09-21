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
        #      allowed `authFields`. Defaults to `["memberNumber"]`.
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
          # `OrgMemberAuthFields`. Order = the order the checkboxes render.
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
          # to unchecked and the identity picker to `["memberNumber"]`. A
          # sidecar that predates this feature stores nothing under
          # `auth_fields` — treat that the same as a fresh opt-in so the
          # checkbox is pre-ticked instead of blank.
          def self.from_model(election)
            sidecar = election.vocdoni_process
            return new if sidecar.blank?

            settings = sidecar.metadata.to_h["settings"].to_h
            two_fa = Array(settings["twofa_fields"]).map(&:to_s)
            stored = Array(settings["auth_fields"]).map(&:to_s).compact_blank
            new(enable_vocdoni: true,
                sms: two_fa.include?("phone"),
                email: two_fa.include?("email"),
                auth_fields: stored.presence || DEFAULT_AUTH_FIELDS)
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

          # The canonical, filtered, sorted list. Simple vote collapses to
          # the default — nothing to persist and nothing to ask a
          # Decidim-only voter. Views use {#auth_field_selected?}, the
          # command persists this, and the publish job reads the same value
          # back through the sidecar.
          def selected_auth_fields
            picked = submitted_auth_fields & AUTH_FIELD_OPTIONS
            return DEFAULT_AUTH_FIELDS.dup unless enable_vocdoni

            picked.sort
          end

          def auth_field_selected?(field)
            selected_auth_fields.include?(field)
          end

          private

          # The raw list as it came from the form: normalised (strings,
          # blanks removed) but NOT filtered against the allowlist. The
          # validators must see this so a rejected field surfaces an error
          # rather than silently disappearing.
          def submitted_auth_fields
            Array(auth_fields).map(&:to_s).compact_blank
          end

          def auth_fields_present
            errors.add(:auth_fields, :blank) if submitted_auth_fields.empty?
          end

          def auth_fields_allowed
            refused = submitted_auth_fields - AUTH_FIELD_OPTIONS
            errors.add(:auth_fields, :inclusion) if refused.any?
          end
        end
      end
    end
  end
end
