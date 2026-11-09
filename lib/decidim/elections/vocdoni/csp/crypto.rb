# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Csp
        # secp256k1 key derivation and Ethereum-style signing in stdlib Ruby
        # (OpenSSL >= 3.2 for KECCAK-256). Byte-compatible with saas-backend
        # `csp/signers/electionkey` and go-ethereum `crypto.Sign`; the specs pin
        # both against the shared vectors.
        module Crypto
          module_function

          N = OpenSSL::BN.new("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141", 16).to_i
          GROUP = OpenSSL::PKey::EC::Group.new("secp256k1")
          TAG_ELECTION_ECDSA = "vocdoni/csp/v3/election-ecdsa"

          def keccak(bytes) = OpenSSL::Digest.new("KECCAK-256").digest(bytes)

          def i2b(int) = [int.to_s(16).rjust(64, "0")].pack("H*")

          def b2i(bytes) = bytes.unpack1("H*").to_i(16)

          # The first keccak(tag ‖ u32be(i) ‖ data), i = 0..255, that is a valid
          # non-zero scalar.
          def hash_to_scalar(tag, data)
            256.times do |i|
              h = b2i(keccak(tag.b + [i].pack("N") + data.b))
              return h if h.between?(1, N - 1)
            end
            raise Csp::Error, "no scalar"
          end

          # dE for one on-chain election: root is 32 bytes, seed the 12-byte
          # SaaS question id.
          def election_key(root, seed)
            raise ArgumentError, "root" unless root.bytesize == 32 && b2i(root).between?(1, N - 1)
            raise ArgumentError, "seed" unless seed.bytesize == 12

            hash_to_scalar(TAG_ELECTION_ECDSA, root.b + seed.b)
          end

          # Compressed (33-byte) public key of a private scalar.
          def public_key(priv) = GROUP.generator.mul(OpenSSL::BN.new(priv)).to_octet_string(:compressed)

          # CAbundle{processId: 1, address: 2, voteWeight: 3} as protobuf, the
          # bytes the chain verifies. With the default weight it is 59 bytes.
          def ca_bundle(process_id, address, weight = "\x01".b)
            valid = process_id.bytesize == 32 && address.bytesize == 20 && weight.bytesize.between?(1, 127)
            raise ArgumentError, "ca_bundle" unless valid

            "\x0a\x20".b + process_id.b + "\x12\x14".b + address.b + "\x1a".b + weight.bytesize.chr.b + weight.b
          end

          # EIP-191 digest. The length is computed from the message, never fixed.
          def eth_digest(msg) = keccak("\x19Ethereum Signed Message:\n#{msg.bytesize}".b + msg.b)

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

          # 65-byte r ‖ s ‖ v, low-s, v in {0,1}, equal to go-ethereum crypto.Sign.
          # The result is recovered and compared with the signer's public key
          # before it is returned, which catches a broken OpenSSL.
          def sign_eth(priv, msg)
            raise ArgumentError, "priv" unless priv.is_a?(Integer) && priv.between?(1, N - 1)

            z = eth_digest(msg)
            k = rfc6979_k(priv, z)
            rp = GROUP.generator.mul(OpenSSL::BN.new(k)).to_octet_string(:uncompressed)
            r = b2i(rp[1, 32]) % N
            v = rp[64].ord & 1
            s = blinded_s(k, b2i(z), r, priv)
            raise Csp::Error, "degenerate signature" if r.zero? || s.zero?

            if s > N / 2
              s = N - s
              v ^= 1
            end
            sig = i2b(r) + i2b(s) + v.chr.b
            raise Csp::Error, "signature self-check failed" unless recover(msg, sig) == public_key(priv)

            sig
          end

          # s = nonce⁻¹(hash + sig_r·priv) mod N. Ruby Integer arithmetic runs in
          # variable time and the signer is a network oracle, so the inverse and
          # the products act on nonce·b and (hash + sig_r·priv)·c for fresh random
          # b, c and are unblinded afterwards. The result is the same integer, so
          # the RFC 6979 output is unchanged.
          def blinded_s(nonce, hash, sig_r, priv)
            b = SecureRandom.random_number(N - 1) + 1
            c = SecureRandom.random_number(N - 1) + 1
            kinv = ((nonce * b) % N).pow(N - 2, N) * b % N
            kinv * (((hash * c) + (sig_r * ((priv * c) % N))) % N) * c.pow(N - 2, N) % N
          end

          # Compressed public key that produced sig over msg (EIP-191), for
          # specs and the signing self-check. Accepts v as 0/1 or 27/28.
          def recover(msg, sig)
            raise ArgumentError, "signature" unless sig.bytesize == 65

            z = b2i(eth_digest(msg))
            r = b2i(sig[0, 32])
            s = b2i(sig[32, 32])
            v = sig[64].ord % 27
            raise ArgumentError, "signature" unless r.between?(1, N - 1) && s.between?(1, N - 1) && v <= 1

            rpt = OpenSSL::PKey::EC::Point.new(GROUP, OpenSSL::BN.new((v.zero? ? "02" : "03") + r.to_s(16).rjust(64, "0"), 16))
            rinv = r.pow(N - 2, N)
            rpt.mul(OpenSSL::BN.new((s * rinv) % N), OpenSSL::BN.new((-z * rinv) % N)).to_octet_string(:compressed)
          end

          # keccak256(address ‖ processId), the chain's vote nullifier.
          def nullifier(address, process_id) = keccak(address.b + process_id.b)
        end
      end
    end
  end
end
