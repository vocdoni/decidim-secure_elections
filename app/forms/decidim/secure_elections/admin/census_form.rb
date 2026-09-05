# frozen_string_literal: true

module Decidim
  module SecureElections
    module Admin
      # Voter authentication: how a person proves they are on the census.
      #
      # This is the Vocdoni app's three-part dialog
      # (`Process/Create/VoterAuthentication/`) expressed as one form object:
      #
      # 1. **Credentials** — up to three member fields the voter has to type.
      # 2. **Two-factor** — off, email, SMS, or the voter's choice. The stored
      #    `twoFaFields` are derived from that single choice, using the app's
      #    mapping (`utils.ts`) so the two implementations cannot drift.
      # 3. **Summary** — a WEAK / MID / STRONG reading of the two together.
      #
      # No Vocdoni identifier appears here. There is deliberately no member
      # group id: Decidim collects the voters and the publish job creates the
      # members, the group and the census upstream.
      #
      # The form is strict about one thing above all: a census with neither a
      # credential nor a second factor identifies *nobody*, and publishing it
      # would enfranchise the whole member list. Refusing it here is the first
      # of three guards; see `Election#census_configured?` and
      # `PublishElectionJob#census_identifies_anybody?`.
      class CensusForm < Decidim::Form
        mimic :census

        # Which census manifest is selected. Only "internal_users" ships today;
        # future manifests plug in by adding a key to
        # `CensusController::CENSUS_MANIFESTS` and a corresponding partial.
        attribute :manifest, String, default: "internal_users"

        attribute :credentials, [String]
        attribute :two_factor_method, String, default: "off"
        attribute :weighted, Boolean, default: false

        validates :two_factor_method, inclusion: { in: ->(_form) { SecureElections::Election::TWO_FA_METHODS.keys } }
        validate :credentials_are_known
        validate :credentials_within_limit
        validate :identifies_somebody

        def map_model(election)
          self.credentials = election.auth_fields
          self.two_factor_method = election.two_fa_method
          self.weighted = election.weighted?
        end

        def election
          @election ||= context[:election]
        end

        # ---------------------------------------------------------------------
        # What gets stored
        # ---------------------------------------------------------------------

        def auth_fields
          Array(credentials).compact_blank & available_credentials
        end

        def two_fa_fields
          SecureElections::Election::TWO_FA_METHODS.fetch(two_factor_method.to_s, [])
        end

        def two_fa?
          two_fa_fields.any?
        end

        # ---------------------------------------------------------------------
        # What the view needs
        # ---------------------------------------------------------------------

        def available_credentials
          SecureElections::CensusMember::CREDENTIAL_FIELDS
        end

        def available_two_factor_methods
          SecureElections::Election::TWO_FA_METHODS.keys
        end

        def max_credentials
          SecureElections::CensusMember::MAX_CREDENTIALS
        end

        # The app's rule, verbatim (`SecurityLevel.tsx#getSecurityLevel`).
        def security_level
          return "strong" if two_fa?

          auth_fields.size >= max_credentials ? "mid" : "weak"
        end

        # The inline advice under the credential checkboxes: nothing with none
        # selected, a nudge with one, a reassurance with two or more.
        #
        # @return [Symbol, nil] `:recommend`, `:good` or nil.
        def credentials_advice
          count = auth_fields.size
          return nil if count.zero?

          count >= 2 ? :good : :recommend
        end

        # Which member column the chosen second factor makes mandatory. Shown
        # in the members table so the admin fills it in *while* entering
        # people, instead of finding out at publish time (ARCHITECTURE §4c-bis).
        def required_two_fa_fields
          two_fa_fields
        end

        private

        def credentials_are_known
          return if (Array(credentials).compact_blank - available_credentials).empty?

          errors.add(:credentials, :inclusion)
        end

        def credentials_within_limit
          return if auth_fields.size <= max_credentials

          errors.add(:credentials, :too_many_credentials, count: max_credentials)
        end

        # The invariant this whole class exists for.
        def identifies_somebody
          return if auth_fields.any? || two_fa?

          errors.add(:credentials, :census_identifies_nobody)
        end
      end
    end
  end
end
