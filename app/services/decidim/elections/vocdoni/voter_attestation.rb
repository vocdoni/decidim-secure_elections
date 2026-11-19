# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Signs the EIP-712 attestation a voter hands to the SaaS CSP's auth/0. The voter is whoever
      # Decidim's census access let into the booth; the SaaS only learns an opaque voterId and, with
      # 2FA, a salted hash of the contact the code goes to.
      class VoterAttestation
        # Long enough to finish the OTP step, well inside the CSP's one-hour ceiling.
        TTL = 10.minutes
        ZERO_HASH = ("\x00" * 32).b

        # Raised when the election sends codes to a `kind` of contact the voter has no valid one of.
        class NoContact < StandardError
          attr_reader :kind

          def initialize(kind)
            @kind = kind
            super("the voter has no #{kind} to send the one-time code to")
          end
        end

        # The canonical `kind` contact ("email" or "phone") a census voter is reached at, or nil. The
        # booth config reads it the same way, so the attested contact and the one it shows match. A
        # voter_uid outside the election's census (another organization's user, another election's row)
        # has no contact.
        def self.contact(election, voter_uid, kind)
          subject = CensusMember.subject_for(election, voter_uid)
          case kind
          when "email" then CensusMember.email(subject)&.then { |email| Attestation.canonical_email(email) }
          when "phone" then Attestation.canonical_phone(CensusMember.phone(subject))
          end
        end

        # Raised when the voter already holds `cap` attestations for the election.
        class CapReached < StandardError; end

        def initialize(process, voter_uid, cap: nil)
          @process = process
          @voter_uid = voter_uid
          @cap = cap
        end

        # Counts a fresh attestation as issued and signs it; the count comes first so the cap also
        # bounds the signing work.
        #
        # @return [Hash] the auth/0 body: `attestation`, `signature` and, with 2FA, the `contact`
        #   and `salt` that open its contactHash.
        # @raise [NoContact, CapReached, Decidim::Elections::Vocdoni::ApiError]
        def call
          contact, salt = contact_and_salt
          message = {
            process_id: Attestation.hex_to_bytes(process.vocdoni_process_id),
            voter_id: process.voter_id_for(voter_uid),
            contact_hash: contact ? Attestation.contact_hash(salt, process.contact_kind, contact) : ZERO_HASH,
            expires_at: (Time.current + TTL).to_i
          }
          digest = Attestation.digest(verifying_contract, **message)
          raise CapReached unless process.record_issued_attestation!(Attestation.bytes_to_hex(message[:voter_id]), cap:)

          signature = Attestation.sign(process.signer_private_key, digest)

          body(message, signature, contact, salt)
        end

        private

        attr_reader :process, :voter_uid, :cap

        def contact_and_salt
          kind = process.contact_kind
          return [nil, nil] if kind.nil?

          contact = self.class.contact(process.election, voter_uid, kind)
          raise NoContact, kind if contact.blank?

          [contact, SecureRandom.bytes(Attestation::SALT_BYTES)]
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
