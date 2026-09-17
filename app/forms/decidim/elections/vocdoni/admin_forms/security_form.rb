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
        #   3. For a "Participants from a file" census, the details voters type
        #      to prove who they are (`identifiers`, 1–3 of the file's
        #      columns). They matter for both vote types, so they are stored
        #      with the census (`census_settings["identifiers"]`), not on the
        #      sidecar.
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
          attribute :identifiers, Array[String], default: [] # rubocop:disable Style/RedundantArrayConstructor -- Decidim attribute type
          attribute :election, Object

          validate :identifiers_count, :identifiers_allowed, :identifiers_unique, if: :file_census_with_list?
          validate :roster_within_limit, if: :enable_vocdoni

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
                email: two_fa.include?("email"),
                identifiers: Array(election.census_settings.to_h["identifiers"]).map(&:to_s))
          end

          def file_census?
            election&.census_manifest.to_s == "token_csv"
          end

          def registered_census?
            election&.census_manifest.to_s == "internal_users"
          end

          # How many people the census holds, as the secure voting service
          # would receive them.
          def census_size
            return 0 if election&.census.blank?

            @census_size ||= election.census.count(election).to_i
          end

          def max_roster
            PublishToVocdoniJob.max_roster
          end

          # A secret vote cannot be set up for a list the secure voting service
          # will refuse; the page says so before the admin chooses it.
          def secure_available?
            census_size <= max_roster || election&.vocdoni_process.present?
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

          def file_census_with_list?
            census_fields.any?
          end

          # Every column that can ever be an identifier, in file order.
          def identifier_options
            census_fields & Fields::SIMPLE_IDENTIFIERS
          end

          def allowed_for_simple?(field) = Fields::SIMPLE_IDENTIFIERS.include?(field)

          def allowed_for_secure?(field) = Fields::AUTH.include?(field)

          def allowed_identifiers
            identifier_options.select { |field| enable_vocdoni ? allowed_for_secure?(field) : allowed_for_simple?(field) }
          end

          # What gets stored: the chosen columns the file has, in file order.
          def chosen_identifiers
            identifier_options & Array(identifiers).map(&:to_s)
          end

          def identifier_selected?(field)
            chosen_identifiers.include?(field)
          end

          # Only name, surname or date of birth, and no one-time code.
          def weak_identifiers?
            chosen = chosen_identifiers
            chosen.any? && (chosen - Fields::WEAK).empty? && !(enable_vocdoni && two_fa_fields.any?)
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

          # SaaS-shape array — the same value we forward verbatim as
          # `twoFaFields` in the process-creation payload. Kept sorted so
          # two equivalent selections do not appear as different diffs.
          def two_fa_fields
            fields = []
            fields << "email" if email && email_code_available?
            fields << "phone" if sms && sms_code_available?
            fields.sort
          end

          private

          def roster_within_limit
            return if census_size <= max_roster

            errors.add(:enable_vocdoni, :roster_too_large, count: census_size, limit: max_roster)
          end

          def identifiers_count
            count = chosen_identifiers.size
            return if count.between?(1, Fields::MAX_IDENTIFIERS)

            errors.add(:identifiers, count.zero? ? :blank : :too_many, count: Fields::MAX_IDENTIFIERS)
          end

          def identifiers_allowed
            refused = chosen_identifiers - allowed_identifiers
            return if refused.empty?

            errors.add(:identifiers, :not_for_secure, fields: labels(refused))
          end

          # The chosen details must tell every person in the list apart.
          def identifiers_unique
            chosen = chosen_identifiers & allowed_identifiers
            return if chosen.empty? || errors[:identifiers].any?

            connection = Decidim::Elections::Voter.connection
            keys = chosen.map { |field| "lower(data->>#{connection.quote(field)})" }
            groups = Decidim::Elections::Voter.where(election:).group(Arel.sql(keys.join(", "))).having("count(*) > 1").count
            return if groups.empty?

            errors.add(:identifiers, :not_unique, count: groups.values.sum, fields: labels(chosen))
          end

          def labels(fields)
            fields.map { |field| Fields.label(field) }.to_sentence
          end
        end
      end
    end
  end
end
