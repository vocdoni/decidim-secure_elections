# frozen_string_literal: true

require "openssl"

module Decidim
  module Elections
    module Vocdoni
      # The `memberNumber` a voter authenticates with against the Vocdoni CSP.
      #
      # It is the only authField of the census, so whoever knows it can
      # request a CSP token for that voter. A sequential Decidim id would let
      # anyone enumerate the census from outside Decidim; an HMAC keyed by a
      # server-side secret cannot be guessed, and only reaches a voter through
      # the booth page once Decidim has let them into the census.
      #
      # The election id is part of the message, so the same person gets an
      # unrelated credential in every election and one leaked credential does
      # not open any other election.
      #
      # {PublishElectionJob} (members it pushes) and {VotingBackend}
      # (`booth_config`) must agree on it, so both go through {.for}.
      module VoterCredential
        # Key-derivation salt: changing it changes every credential, which
        # breaks the CSP login of every election already published.
        SALT = "decidim-elections-vocdoni voter credential v1"

        module_function

        # @param election [Decidim::Elections::Election]
        # @param subject [Decidim::User, Decidim::Elections::Voter] a census
        #   entry: a participant of an `internal_users` census or a row of a
        #   `token_csv` one.
        # @return [String, nil] 64 hex characters, or nil for an unknown subject.
        def for(election, subject)
          message = message_for(election, subject)
          return nil if message.nil?

          OpenSSL::HMAC.hexdigest("SHA256", secret, message)
        end

        # The census entry behind the `voter_uid` Decidim's census manifests
        # mint (a GlobalID of the user or of the CSV row), or nil when it does
        # not belong to this election's census.
        def subject_for(election, voter_uid)
          return nil if voter_uid.blank?

          subject = GlobalID::Locator.locate(voter_uid, only: [Decidim::User, Decidim::Elections::Voter])
          case subject
          when Decidim::User
            subject if subject.decidim_organization_id == election.organization.id
          when Decidim::Elections::Voter
            subject if subject.election_id == election.id
          end
        rescue ActiveRecord::RecordNotFound, URI::Error, NameError
          nil
        end

        # What a credential looks like, to scrub it from anything an admin or
        # a log may read: error messages and the SaaS error payloads kept in
        # the process metadata.
        PATTERN = /\b[0-9a-f]{64}\b/i

        # @param text [String, nil]
        # @return [String]
        def redact(text)
          text.to_s.gsub(PATTERN, "[CREDENTIAL]")
        end

        # Users are hashed as `"<election id>:<user id>"`; CSV rows carry a
        # `voter:` prefix so a row id can never produce a user's credential.
        def message_for(election, subject)
          case subject
          when Decidim::User then "#{election.id}:#{subject.id}"
          when Decidim::Elections::Voter then "#{election.id}:voter:#{subject.id}"
          end
        end

        # `VOCDONI_CREDENTIAL_SECRET` overrides the key, for an installation
        # that rotates `secret_key_base` and must keep live elections working.
        # Otherwise the key is derived from `secret_key_base` with a dedicated
        # salt, so it never equals a key Rails derives for cookies or
        # messages, and a leaked credential tells nothing about them.
        def secret
          ENV.fetch("VOCDONI_CREDENTIAL_SECRET", nil).presence ||
            Rails.application.key_generator.generate_key(SALT, 32)
        end
      end
    end
  end
end
