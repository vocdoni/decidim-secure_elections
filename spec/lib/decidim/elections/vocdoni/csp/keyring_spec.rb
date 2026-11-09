# frozen_string_literal: true

require "pp"
require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      module Csp
        describe Keyring do
          let(:vectors) { JSON.parse(File.read(File.expand_path("../../../../../fixtures/csp/csp-v3-vectors.json", __dir__))) }
          let(:root_hex) { vectors["root"] }
          let(:root) { [root_hex].pack("H*") }
          let(:root_id) { described_class.id_for(root) }
          let(:other_hex) { Crypto.i2b(SecureRandom.random_number(Crypto::N - 1) + 1).unpack1("H*") }
          let(:other_id) { described_class.id_for([other_hex].pack("H*")) }
          let(:keyring) { described_class.load("#{root_id}:#{root_hex}, #{other_id}:#{other_hex}") }

          def expect_secret_free(error, *secrets)
            secrets.each do |secret|
              expect(error.message).not_to include(secret)
              expect(error.message.downcase).not_to include(secret.downcase)
            end
          end

          it "derives the id as the first 8 bytes of keccak(compressed public key)" do
            pub = Crypto.public_key(Crypto.b2i(root))
            expect(root_id).to eq(Crypto.keccak(pub)[0, 8].unpack1("H*"))
            expect(root_id).to match(/\A\h{16}\z/)
          end

          it "parses id:hex entries in order" do
            expect(keyring.ids).to eq([root_id, other_id])
            expect(keyring.fetch(root_id)).to eq(root)
            expect(keyring.fetch(other_id)).to eq([other_hex].pack("H*"))
          end

          it "takes the last entry as the newest" do
            expect(keyring.newest_id).to eq(other_id)
          end

          it "loads an empty keyring from an empty value" do
            empty = described_class.load("")
            expect(empty).to be_empty
            expect { empty.newest_id }.to raise_error(RootMissing)
          end

          it "raises RootMissing for an unknown id, without falling back" do
            expect { keyring.fetch("0123456789abcdef") }.to raise_error(RootMissing) { |e| expect(e.code).to eq("csp_root_missing") }
          end

          it "raises naming the id only when the id does not match its root" do
            expect { described_class.load("0000000000000000:#{root_hex}") }
              .to raise_error(ConfigurationError) { |e|
                expect(e.message).to include("0000000000000000")
                expect_secret_free(e, root_hex)
              }
          end

          it "rejects malformed entries without printing them" do
            ["#{root_id}:#{root_hex[0, 62]}", root_hex, "#{root_id}:#{root_hex}zz"].each do |value|
              expect { described_class.load(value) }.to raise_error(ConfigurationError) { |e| expect_secret_free(e, root_hex[0, 62]) }
            end
          end

          it "rejects a zero or out-of-range root" do
            zero = "00" * 32
            n_hex = Crypto::N.to_s(16)
            expect { described_class.load("0000000000000000:#{zero}") }.to raise_error(ConfigurationError) { |e| expect_secret_free(e, zero) }
            expect { described_class.load("0000000000000000:#{n_hex}") }.to raise_error(ConfigurationError) { |e| expect_secret_free(e, n_hex) }
          end

          it "rejects duplicate ids" do
            expect { described_class.load("#{root_id}:#{root_hex},#{root_id}:#{root_hex}") }
              .to raise_error(ConfigurationError, /duplicate/) { |e| expect_secret_free(e, root_hex) }
          end

          it "shows ids only in inspect, to_s, pp and as_json" do
            outputs = [keyring.inspect, keyring.to_s, PP.pp(keyring, +""), keyring.as_json.to_s, keyring.to_json]
            outputs.each do |out|
              expect(out).to include(root_id)
              expect(out).not_to include(root_hex)
              expect(out).not_to include(other_hex)
            end
          end

          it "compares roots without exposing them" do
            expect(keyring.include_root?(root)).to be(true)
            expect(keyring.include_root?(SecureRandom.random_bytes(32))).to be(false)
            expect(keyring.include_root?("short")).to be(false)
          end

          describe "#assert_prod_safe!" do
            before { stub_const("#{described_class}::NON_PROD_ROOT_IDS", [root_id].freeze) }

            it "raises on the LTS chain with a denied id, naming ids only" do
              expect { keyring.assert_prod_safe!("vocdoni/LTS/1.3") }
                .to raise_error(ConfigurationError) { |e|
                  expect(e.message).to include(root_id)
                  expect_secret_free(e, root_hex)
                }
            end

            it "allows the denied id on DEV and STAGE chains" do
              expect(keyring.assert_prod_safe!("vocdoni/DEV/36")).to be(true)
              expect(keyring.assert_prod_safe!("vocdoni/STAGE/12")).to be(true)
            end

            it "allows the LTS chain when every id is allowed" do
              prod = described_class.load("#{other_id}:#{other_hex}")
              expect(prod.assert_prod_safe!("vocdoni/LTS/1.3")).to be(true)
            end
          end
        end
      end
    end
  end
end
