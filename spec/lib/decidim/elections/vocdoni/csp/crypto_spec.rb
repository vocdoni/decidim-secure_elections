# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      module Csp
        describe Crypto do
          let(:fixtures) { File.expand_path("../../../../../fixtures/csp", __dir__) }
          let(:vectors) { JSON.parse(File.read(File.join(fixtures, "csp-v3-vectors.json"))) }
          let(:hex) { ->(h) { [h].pack("H*") } }
          let(:root) { hex.call(vectors["root"]) }
          let(:elections) { vectors["elections"] }
          let(:seed0) { hex.call(elections[0]["seed"]) }
          let(:seed1) { hex.call(elections[1]["seed"]) }
          let(:d_e0) { described_class.election_key(root, seed0) }
          let(:proof) { vectors["proofs"].find { |p| p["name"] == "ecdsa weight 42" } }
          let(:process_id) { hex.call(proof["processId"]) }
          let(:address) { hex.call(proof["address"]) }
          let(:n) { described_class::N }

          def to_hex(bytes) = bytes.unpack1("H*")

          it "uses the secp256k1 group order" do
            expect(n).to eq(OpenSSL::PKey::EC::Group.new("secp256k1").order.to_i)
          end

          it "computes Keccak-256, not SHA3-256" do
            expect(to_hex(described_class.keccak(""))).to eq("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
          end

          describe ".election_key" do
            it "derives the vector key pair for both seeds" do
              elections.each do |election|
                priv = described_class.election_key(root, hex.call(election["seed"]))
                expect(described_class.i2b(priv)).to eq(hex.call(election["electionEcdsaKey"]["private"]))
                expect(described_class.public_key(priv)).to eq(hex.call(election["electionEcdsaKey"]["public"]))
              end
            end

            it "rejects a root of the wrong size or out of range" do
              expect { described_class.election_key(root[0, 31], seed0) }.to raise_error(ArgumentError, "root")
              expect { described_class.election_key("\x00".b * 32, seed0) }.to raise_error(ArgumentError, "root")
              expect { described_class.election_key(described_class.i2b(n), seed0) }.to raise_error(ArgumentError, "root")
            end

            it "rejects a seed that is not 12 bytes" do
              expect { described_class.election_key(root, seed0[0, 11]) }.to raise_error(ArgumentError, "seed")
            end
          end

          describe "the \"ecdsa weight 42\" proof" do
            let(:bundle) { described_class.ca_bundle(process_id, address, "\x2a".b) }

            it "builds the vector bundle" do
              expect(bundle).to eq(hex.call(proof["bundle"]))
              expect(bundle.bytesize).to eq(59)
            end

            it "signs byte-identically to go-ethereum crypto.Sign" do
              expect(to_hex(described_class.sign_eth(d_e0, bundle))).to eq(proof["signature"])
            end

            it "stays byte-identical across calls with fresh blinding factors" do
              expect(SecureRandom).to receive(:random_number).at_least(10).times.and_call_original
              sigs = Array.new(5) { described_class.sign_eth(d_e0, bundle) }
              expect(sigs.map { |s| to_hex(s) }.uniq).to eq([proof["signature"]])
            end

            it "recovers to the seed0 census root and not to seed1's" do
              sig = hex.call(proof["signature"])
              recovered = described_class.recover(bundle, sig)
              expect(recovered).to eq(hex.call(proof["censusRoot"]))
              expect(recovered).to eq(hex.call(elections[0]["electionEcdsaKey"]["public"]))
              expect(recovered).not_to eq(hex.call(elections[1]["electionEcdsaKey"]["public"]))
            end

            it "hashes with the computed length prefix \\n59" do
              prefix = "\x19Ethereum Signed Message:\n59".b
              expect(to_hex(prefix)).to eq("19457468657265756d205369676e6564204d6573736167653a0a3539")
              expect(described_class.eth_digest(bundle)).to eq(described_class.keccak(prefix + bundle))
              wrong = described_class.keccak("\x19Ethereum Signed Message:\n58".b + bundle)
              expect(wrong).not_to eq(described_class.eth_digest(bundle))
            end
          end

          describe ".ca_bundle" do
            it "is 0a20‖pid‖1214‖addr‖1a0101 (59 bytes) with the default weight" do
              bundle = described_class.ca_bundle(process_id, address)
              expect(bundle.bytesize).to eq(59)
              expect(to_hex(bundle)).to eq("0a20#{proof["processId"]}1214#{proof["address"]}1a0101")
              expect(bundle.encoding).to eq(Encoding::BINARY)
            end

            it "signs a weight-01 bundle that recovers to the census root" do
              bundle = described_class.ca_bundle(process_id, address)
              sig = described_class.sign_eth(d_e0, bundle)
              expect(sig.bytesize).to eq(65)
              expect(described_class.recover(bundle, sig)).to eq(hex.call(elections[0]["electionEcdsaKey"]["public"]))
            end

            it "rejects malformed inputs" do
              expect { described_class.ca_bundle(process_id[0, 31], address) }.to raise_error(ArgumentError)
              expect { described_class.ca_bundle(process_id, address[0, 19]) }.to raise_error(ArgumentError)
              expect { described_class.ca_bundle(process_id, address, "".b) }.to raise_error(ArgumentError)
              expect { described_class.ca_bundle(process_id, address, "\x01".b * 128) }.to raise_error(ArgumentError)
            end
          end

          describe "the OFF_CHAIN_CA_V2 weight-01 fixture (csp-external-v2-ecdsa.json)" do
            let(:v2_path) { File.join(fixtures, "csp-external-v2-ecdsa.json") }

            before do
              skip "csp-external-v2-ecdsa.json is generated by saas-backend T2 and copied here once committed" unless File.exist?(v2_path)
            end

            it "reproduces bundle, digest, signature and nullifier byte for byte" do
              fx = JSON.parse(File.read(v2_path))
              expect(fx).to include("censusOrigin" => "OFF_CHAIN_CA_V2", "proofType" => "ECDSA", "voteWeight" => "01")
              expect(fx["root"]).to eq(vectors["root"])
              d_e = described_class.election_key(hex.call(fx["root"]), hex.call(fx["seed"]))
              expect(to_hex(described_class.public_key(d_e))).to eq(fx["censusRoot"])
              pid = hex.call(fx["processId"])
              addr = hex.call(fx["address"])
              bundle = described_class.ca_bundle(pid, addr, hex.call(fx["voteWeight"]))
              expect(bundle.bytesize).to eq(59)
              expect(to_hex(bundle)).to eq(fx["bundle"])
              expect(to_hex(described_class.eth_digest(bundle))).to eq(fx["digest"])
              expect(to_hex(described_class.sign_eth(d_e, bundle))).to eq(fx["signature"])
              expect(described_class.recover(bundle, hex.call(fx["signature"]))).not_to eq(hex.call(fx["wrongCensusRoot"]))
              expect(to_hex(described_class.nullifier(addr, pid))).to eq(fx["nullifier"])
            end
          end

          describe ".sign_eth" do
            it "produces low-s, v in {0,1} signatures that recover, over 200 random keys and messages" do
              half = n / 2
              vs = []
              200.times do
                priv = SecureRandom.random_number(n - 1) + 1
                msg = SecureRandom.random_bytes(SecureRandom.random_number(1..120))
                sig = described_class.sign_eth(priv, msg)
                expect(sig.bytesize).to eq(65)
                expect(described_class.b2i(sig[32, 32])).to be <= half
                expect(sig[64].ord).to be_between(0, 1)
                expect(described_class.recover(msg, sig)).to eq(described_class.public_key(priv))
                vs << sig[64].ord
              end
              expect(vs.uniq.sort).to eq([0, 1])
            end

            it "flips v when it negates a high s" do
              msg = "flip".b
              priv = d_e0
              z = described_class.b2i(described_class.eth_digest(msg))
              k = described_class.rfc6979_k(priv, described_class.eth_digest(msg))
              rp = described_class::GROUP.generator.mul(OpenSSL::BN.new(k)).to_octet_string(:uncompressed)
              r = described_class.b2i(rp[1, 32])
              raw_s = k.pow(n - 2, n) * (z + (r * priv)) % n
              sig = described_class.sign_eth(priv, msg)
              expected_v = (rp[64].ord & 1) ^ (raw_s > n / 2 ? 1 : 0)
              expect(sig[64].ord).to eq(expected_v)
              expect(described_class.b2i(sig[32, 32])).to eq([raw_s, n - raw_s].min)
            end

            it "raises when the signature does not recover to the signer" do
              allow(described_class).to receive(:recover).and_return("\x02".b * 33)
              expect { described_class.sign_eth(d_e0, "x".b) }.to raise_error(Csp::Error, /self-check/)
            end

            it "rejects a key outside [1, N-1]" do
              expect { described_class.sign_eth(0, "x".b) }.to raise_error(ArgumentError)
              expect { described_class.sign_eth(n, "x".b) }.to raise_error(ArgumentError)
            end
          end

          describe ".blinded_s" do
            it "equals k⁻¹(z + r·priv) mod N over 200 random inputs" do
              200.times do
                k, z, r, priv = Array.new(4) { SecureRandom.random_number(n - 1) + 1 }
                expect(described_class.blinded_s(k, z, r, priv)).to eq(k.pow(n - 2, n) * (z + (r * priv)) % n)
              end
            end

            it "draws fresh blinding factors on every call" do
              expect(SecureRandom).to receive(:random_number).with(n - 1).twice.and_return(5, 7)
              described_class.blinded_s(11, 13, 17, 19)
            end
          end

          describe ".recover" do
            it "accepts v as 27/28" do
              sig = hex.call(proof["signature"])
              eth_sig = sig[0, 64] + (sig[64].ord + 27).chr.b
              bundle = hex.call(proof["bundle"])
              expect(described_class.recover(bundle, eth_sig)).to eq(hex.call(proof["censusRoot"]))
            end

            it "rejects malformed signatures" do
              expect { described_class.recover("x".b, "\x00".b * 64) }.to raise_error(ArgumentError)
              expect { described_class.recover("x".b, ("\x00".b * 64) + "\x00".b) }.to raise_error(ArgumentError)
            end
          end

          it "computes the nullifier as keccak(address ‖ processId)" do
            expect(described_class.nullifier(address, process_id)).to eq(described_class.keccak(address + process_id))
            expect(described_class.nullifier(address, process_id).bytesize).to eq(32)
          end
        end
      end
    end
  end
end
