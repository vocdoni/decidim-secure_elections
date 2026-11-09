# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Signs the EIP-712 attestation a voter of an attested census hands to the SaaS CSP in place
      # of a member credential. The voter is whoever Decidim's census access let into the booth; the
      # SaaS only learns an opaque voterId and, with email 2FA, a salted hash of the address the
      # code goes to.
      class VoterAttestation
        # Long enough to finish the OTP step, well inside the CSP's one-hour ceiling.
        TTL = 10.minutes
        ZERO_HASH = ("\x00" * 32).b

        # Raised when the election sends codes by email and the voter has no email on file.
        class NoContact < StandardError; end

        # The email a census voter is reached at: the account email of a user, the `email` column
        # of a census row.
        def self.contact_email(voter_uid)
          case (record = GlobalID::Locator.locate(voter_uid.to_s))
          when Decidim::User then record.email
          when Decidim::Elections::Voter then record.data.to_h["email"]
          end
        end

        def initialize(process, voter_uid)
          @process = process
          @voter_uid = voter_uid
        end

        # Signs a fresh attestation and counts it as issued.
        #
        # @return [Hash] the auth/0 body: `attestation`, `signature` and, with email 2FA, the
        #   `contact` and `salt` that open its contactHash.
        # @raise [NoContact, Decidim::Elections::Vocdoni::ApiError]
        def call
          contact, salt = contact_and_salt
          message = {
            process_id: Attestation.hex_to_bytes(process.vocdoni_process_id),
            voter_id: process.voter_id_for(voter_uid),
            contact_hash: contact ? Attestation.contact_hash(salt, "email", contact) : ZERO_HASH,
            expires_at: (Time.current + TTL).to_i
          }
          signature = Attestation.sign(process.signer_private_key, Attestation.digest(verifying_contract, **message))
          process.record_issued_attestation!(Attestation.bytes_to_hex(message[:voter_id]))

          body(message, signature, contact, salt)
        end

        private

        attr_reader :process, :voter_uid

        def contact_and_salt
          return [nil, nil] unless Array(process.metadata.to_h.dig("settings", "twofa_fields")).include?("email")

          email = self.class.contact_email(voter_uid)
          raise NoContact if email.blank?

          [Attestation.canonical_email(email), SecureRandom.bytes(Attestation::SALT_BYTES)]
        end

        # The verifyingContract of the SaaS environment's domain, read from the process once and
        # kept in the process metadata.
        def verifying_contract
          address = process.metadata.to_h["attestation_verifying_contract"]
          if address.blank?
            address = ApiClient.new.elections.get(process.vocdoni_process_id).to_h.dig("census", "attested", "verifyingContract")
            raise ApiError.new("the SaaS process has no attestation domain", transient: false) if address.blank?

            process.with_lock do
              process.update!(metadata: process.metadata.to_h.merge("attestation_verifying_contract" => address))
            end
          end
          Attestation.hex_to_bytes(address)
        end

        def body(message, signature, contact, salt)
          hex = ->(bytes) { bytes.unpack1("H*") }
          {
            attestation: {
              processId: hex.call(message[:process_id]),
              voterId: hex.call(message[:voter_id]),
              contactHash: hex.call(message[:contact_hash]),
              expiresAt: message[:expires_at]
            },
            signature: hex.call(signature),
            contact:,
            salt: salt && hex.call(salt)
          }.compact
        end
      end
    end
  end
end
