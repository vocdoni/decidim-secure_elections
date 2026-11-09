# frozen_string_literal: true

require "openssl"
require "securerandom"

module Decidim
  module Elections
    module Vocdoni
      # EIP-712 attestations Decidim signs for the voters of an attested census, in stdlib Ruby
      # (OpenSSL >= 3.2 for KECCAK-256). Byte-compatible with saas-backend `csp/attestation`; the
      # spec pins it against the vectors that package exports.
      module Attestation
        class Error < StandardError; end

        module_function

        DOMAIN_NAME = "Vocdoni CSP attestation"
        DOMAIN_VERSION = "1"
        N = OpenSSL::BN.new("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141", 16).to_i
        GROUP = OpenSSL::PKey::EC::Group.new("secp256k1")
        SALT_BYTES = 32

        def keccak(bytes) = OpenSSL::Digest.new("KECCAK-256").digest(bytes)

        def i2b(int, size = 32) = [int.to_s(16).rjust(size * 2, "0")].pack("H*")

        def b2i(bytes) = bytes.unpack1("H*").to_i(16)

        def hex_to_bytes(hex) = [hex.delete_prefix("0x")].pack("H*")

        def bytes_to_hex(bytes) = "0x#{bytes.unpack1("H*")}"

        DOMAIN_TYPEHASH = keccak("EIP712Domain(string name,string version,address verifyingContract)")
        ATTESTATION_TYPEHASH = keccak("Attestation(bytes12 processId,bytes32 voterId,bytes32 contactHash,uint64 expiresAt)")

        # keccak256(typeHash ‖ keccak(name) ‖ keccak(version) ‖ address left-padded), the domain of
        # one SaaS environment: verifying_contract is the address of its CSP signer.
        def domain_separator(verifying_contract)
          contract = verifying_contract.b
          raise ArgumentError, "verifying_contract" unless contract.bytesize == 20

          keccak(DOMAIN_TYPEHASH + keccak(DOMAIN_NAME) + keccak(DOMAIN_VERSION) + ("\x00".b * 12) + contract)
        end

        # hashStruct(Attestation): bytes12 right-padded, uint64 left-padded to 32 bytes.
        def struct_hash(process_id:, voter_id:, contact_hash:, expires_at:)
          raise ArgumentError, "process_id" unless process_id.bytesize == 12
          raise ArgumentError, "voter_id" unless voter_id.bytesize == 32
          raise ArgumentError, "contact_hash" unless contact_hash.bytesize == 32
          raise ArgumentError, "expires_at" unless expires_at.is_a?(Integer) && expires_at.between?(0, (2**64) - 1)

          keccak(ATTESTATION_TYPEHASH + process_id.b + ("\x00".b * 20) + voter_id.b + contact_hash.b + i2b(expires_at))
        end

        # keccak256(0x19 0x01 ‖ domainSeparator ‖ structHash), the digest the signer signs.
        def digest(verifying_contract, **fields)
          keccak("\x19\x01".b + domain_separator(verifying_contract) + struct_hash(**fields))
        end

        # keccak256(salt ‖ utf8(kind ‖ ":" ‖ contact)). The contact must already be canonical.
        def contact_hash(salt, kind, contact)
          raise ArgumentError, "salt" unless salt.bytesize == SALT_BYTES
          raise ArgumentError, "kind" unless %w(email phone).include?(kind)

          keccak(salt.b + "#{kind}:#{contact}".b)
        end

        # The canonical form of an email the SaaS accepts: trimmed, lowercase, NFC.
        def canonical_email(email) = email.to_s.strip.downcase.unicode_normalize(:nfc)

        # The 20-byte address of a private scalar.
        def address(priv)
          point = GROUP.generator.mul(OpenSSL::BN.new(priv)).to_octet_string(:uncompressed)
          keccak(point[1, 64])[12, 20]
        end

        # 65-byte r ‖ s ‖ v over a 32-byte digest: RFC 6979 nonce, low-s, v ∈ {27, 28}, as
        # go-ethereum crypto.Sign plus 27. The signature is recovered and compared with the signer's
        # address before it is returned, which catches a broken OpenSSL.
        def sign(priv, digest)
          raise ArgumentError, "priv" unless priv.is_a?(Integer) && priv.between?(1, N - 1)
          raise ArgumentError, "digest" unless digest.bytesize == 32

          k = rfc6979_k(priv, digest)
          rp = GROUP.generator.mul(OpenSSL::BN.new(k)).to_octet_string(:uncompressed)
          r = b2i(rp[1, 32]) % N
          v = rp[64].ord & 1
          s = blinded_s(k, b2i(digest), r, priv)
          raise Error, "degenerate signature" if r.zero? || s.zero?

          if s > N / 2
            s = N - s
            v ^= 1
          end
          sig = i2b(r) + i2b(s) + (v + 27).chr.b
          raise Error, "signature self-check failed" unless recover(digest, sig) == address(priv)

          sig
        end

        # The address that produced sig over digest. Accepts v as 0/1 or 27/28.
        def recover(digest, sig)
          raise ArgumentError, "signature" unless sig.bytesize == 65

          z = b2i(digest)
          r = b2i(sig[0, 32])
          s = b2i(sig[32, 32])
          v = sig[64].ord % 27
          raise ArgumentError, "signature" unless r.between?(1, N - 1) && s.between?(1, N - 1) && v <= 1

          rpt = OpenSSL::PKey::EC::Point.new(GROUP, OpenSSL::BN.new((v.zero? ? "02" : "03") + r.to_s(16).rjust(64, "0"), 16))
          rinv = r.pow(N - 2, N)
          pub = rpt.mul(OpenSSL::BN.new((s * rinv) % N), OpenSSL::BN.new((-z * rinv) % N)).to_octet_string(:uncompressed)
          keccak(pub[1, 64])[12, 20]
        end

        # Deterministic nonce (RFC 6979, HMAC-SHA256) as libsecp256k1 derives it.
        def rfc6979_k(priv, digest)
          x = i2b(priv)
          v = "\x01".b * 32
          k = "\x00".b * 32
          hm = ->(kk, m) { OpenSSL::HMAC.digest("SHA256", kk, m) }
          k = hm.call(k, v + "\x00".b + x + digest)
          v = hm.call(k, v)
          k = hm.call(k, v + "\x01".b + x + digest)
          v = hm.call(k, v)
          loop do
            v = hm.call(k, v)
            t = b2i(v)
            return t if t.between?(1, N - 1)

            k = hm.call(k, v + "\x00".b)
            v = hm.call(k, v)
          end
        end

        # s = nonce⁻¹(hash + r·priv) mod N. Ruby Integer arithmetic runs in variable time and the
        # signer answers any authenticated voter, so the inverse and the products act on values
        # blinded by fresh random b, c and are unblinded afterwards; the result is the same integer.
        def blinded_s(nonce, hash, sig_r, priv)
          b = SecureRandom.random_number(N - 1) + 1
          c = SecureRandom.random_number(N - 1) + 1
          kinv = ((nonce * b) % N).pow(N - 2, N) * b % N
          kinv * (((hash * c) + (sig_r * ((priv * c) % N))) % N) * c.pow(N - 2, N) % N
        end
      end
    end
  end
end
