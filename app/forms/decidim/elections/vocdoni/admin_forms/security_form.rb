# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module AdminForms
        # Security tab form. Owns two things:
        #
        #   1. Whether the election opts in to Vocdoni-backed secure voting
        #      (`enable_vocdoni`). Opt-in is materialised as the presence of
        #      the {Process} sidecar row.
        #
        #   2. The second-factor challenge for CSP authentication. Two
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
        # `metadata["settings"]` hash. The Publish subscription checks
        # `election.vocdoni_process.present?` to decide whether to enqueue
        # {PublishToVocdoniJob}.
        class SecurityForm < Decidim::Form
          mimic :security

          attribute :enable_vocdoni, Boolean, default: false
          attribute :sms, Boolean, default: false
          attribute :email, Boolean, default: false

          # Reconstructs a form from the sidecar. An election that has never
          # visited the Security tab has no sidecar; every checkbox defaults
          # to unchecked.
          def self.from_model(election)
            sidecar = election.vocdoni_process
            return new if sidecar.blank?

            settings = sidecar.metadata.to_h["settings"].to_h
            two_fa = Array(settings["twofa_fields"]).map(&:to_s)
            new(enable_vocdoni: true,
                sms: two_fa.include?("phone"),
                email: two_fa.include?("email"))
          end

          # Summary levels shown on the tab, from least to most protected.
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
        end
      end
    end
  end
end
