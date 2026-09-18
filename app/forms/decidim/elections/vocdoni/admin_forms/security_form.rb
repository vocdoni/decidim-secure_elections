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
        #      independent booleans (SMS and Email) that map onto the
        #      Vocdoni SaaS `twoFaFields` array (`"phone"` and `"email"`
        #      respectively). All four combinations are valid:
        #
        #        [] []  → no OTP (weakest, only CSP identity)
        #        [x] [] → SMS OTP only
        #        [] [x] → Email OTP only
        #        [x] [x] → voter picks at auth time (SaaS OR)
        #
        # The details voters type to prove who they are belong to the census,
        # and a simple vote needs them too, so they are chosen on the Census tab
        # and only read here, to say whether a secret vote can accept them.
        #
        # Persisted through {Admin::UpdateElectionSecurity} onto the sidecar's
        # `metadata["settings"]` hash. The Publish subscription checks
        # `election.vocdoni_process.present?` to decide whether to enqueue
        # {PublishToVocdoniJob}.
        class SecurityForm < Decidim::Form
          mimic :security

          Fields = CensusCsv::Fields

          attribute :enable_vocdoni, Boolean, default: false
          attribute :sms, Boolean, default: false
          attribute :email, Boolean, default: false
          attribute :election, Object

          # Reconstructs a form from the sidecar and the census. An election
          # that has never visited the Security tab has no sidecar; every
          # checkbox defaults to unchecked.
          def self.from_model(election)
            sidecar = election.vocdoni_process
            settings = sidecar&.metadata.to_h["settings"].to_h
            two_fa = Array(settings["twofa_fields"]).map(&:to_s)
            new(election:,
                enable_vocdoni: sidecar.present?,
                sms: two_fa.include?("phone"),
                email: two_fa.include?("email"))
          end

          # {.from_model} passes the election as an attribute, while the
          # controller's `from_params(params, election:)` puts it in the
          # form's context instead. Read both: with a nil election every
          # predicate below answers "no", and the rules this form exists to
          # enforce are silently skipped on save.
          def election
            super || (context[:election] if context)
          end

          def file_census?
            election&.census_manifest.to_s == "token_csv"
          end

          def registered_census?
            election&.census_manifest.to_s == "internal_users"
          end

          # How many people a secret vote may hold is the organisation's own
          # quota with the secure voting service, which this platform cannot
          # read. Guessing it here only ever refused lists the service would
          # have accepted, so size is no longer judged before the fact: the
          # census is pushed and the service answers, and its answer is what
          # the pre-flight on this page reports.
          #
          # What is left is the one thing this platform does know: a list the
          # service cannot authenticate at all.
          def secure_available?
            !secure_blocked_by_identifiers?
          end

          # The details voters type, chosen with the census on the Census tab.
          def identifiers
            return [] unless file_census?

            @identifiers ||= census_fields & Array(election.census_settings.to_h["identifiers"]).map(&:to_s)
          end

          # Titles, for a list of boxes.
          def identifier_labels
            identifiers.map { |field| Fields.label(field) }
          end

          # The same details as they read inside a sentence, which is how this
          # tab reports them and how the Census tab states them.
          def identifier_names
            identifiers.map { |field| Fields.in_sentence(field) }
          end

          # What a secret vote would send as its `authFields`.
          def secure_identifiers
            identifiers & Fields::AUTH
          end

          # The list is identified only by details the secure voting service
          # cannot use at all: in practice an access code we hand out, which
          # it will neither check nor deliver a code to. Nothing here can fix
          # that (the choice belongs to the census), so the card says where.
          def secure_blocked_by_identifiers?
            file_census? && identifiers.any? && !identifiers.intersect?(Fields::SECURE_IDENTIFIERS)
          end

          # A contact detail chosen as the way people identify themselves is
          # not a preference: the code sent there is what proves the person,
          # so the channel is on and cannot be turned off here.
          def code_required?(field)
            file_census? && identifiers.include?(field.to_s)
          end

          def required_code_labels
            code_identifiers.map { |field| Fields.in_sentence(field) }
          end

          def code_identifiers
            identifiers & Fields::TWO_FA
          end

          # The columns the uploaded file was mapped to. A list uploaded with
          # upstream's own importer has no settings; its rows carry the keys.
          def census_fields
            return [] unless file_census?

            @census_fields ||= begin
              fields = Array(election.census_settings.to_h["fields"]).map(&:to_s)
              fields = election.voters.first&.data.to_h.keys.map(&:to_s) if fields.empty?
              fields & Fields::TARGETS
            end
          end

          # The one-time code needs somewhere to go: a file census needs the
          # matching column; registered participants always have an email
          # address but Decidim keeps no phone number for them.
          def email_code_available?
            return true if election.blank?

            !file_census? || census_fields.include?("email")
          end

          def sms_code_available?
            return true if election.blank?

            file_census? && census_fields.include?("phone")
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

          # SaaS-shape array: the same value we forward verbatim as
          # `twoFaFields` in the process-creation payload. Kept sorted so
          # two equivalent selections do not appear as different diffs.
          def two_fa_fields
            fields = []
            fields << "email" if (email || code_required?("email")) && email_code_available?
            fields << "phone" if (sms || code_required?("phone")) && sms_code_available?
            fields.sort
          end
        end
      end
    end
  end
end
