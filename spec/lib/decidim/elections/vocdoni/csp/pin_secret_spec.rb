# frozen_string_literal: true

require "pp"
require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      module Csp
        describe PinSecret do
          let(:secret_hex) { SecureRandom.hex(32) }
          let(:pin_secret) { described_class.load(secret_hex) }
          let(:election) { instance_double(Decidim::Elections::Election, id: 42) }

          def random_root_entry
            root = Crypto.i2b(SecureRandom.random_number(Crypto::N - 1) + 1)
            "#{Keyring.id_for(root)}:#{root.unpack1("H*")}"
          end

          def expect_secret_free(error)
            expect(error.message.downcase).not_to include(secret_hex.downcase)
          end

          it "derives the id as the first 8 bytes of keccak(secret)" do
            expect(pin_secret.id).to eq(Crypto.keccak([secret_hex].pack("H*"))[0, 8].unpack1("H*"))
          end

          it "computes a stable HMAC-SHA256 digest" do
            key = "user:42:7"
            expected = OpenSSL::HMAC.hexdigest("SHA256", [secret_hex].pack("H*"), key)
            expect(pin_secret.digest(key)).to eq(expected)
            expect(described_class.load(secret_hex).digest(key)).to eq(expected)
            expect(pin_secret.digest("user:42:8")).not_to eq(expected)
          end

          it "keeps every digest when a keyring root is added" do
            keys = %w(user:42:7 row:42:9 user:43:7)
            before = keys.map { |k| pin_secret.digest(k) }
            first = random_root_entry
            [Keyring.load(first), Keyring.load("#{first},#{random_root_entry}")].each do |keyring|
              expect(pin_secret.assert_separate!(keyring)).to be(true)
              expect(keys.map { |k| pin_secret.digest(k) }).to eq(before)
            end
          end

          it "raises when the secret equals a root, without printing it" do
            root = Crypto.i2b(SecureRandom.random_number(Crypto::N - 1) + 1)
            root_hex = root.unpack1("H*")
            keyring = Keyring.load("#{Keyring.id_for(root)}:#{root_hex}")
            same = described_class.load(root_hex)
            expect { same.assert_separate!(keyring) }.to raise_error(ConfigurationError) { |e|
              expect(e.message.downcase).not_to include(root_hex)
            }
          end

          it "raises RootMissing when unset" do
            [nil, "", "  "].each do |value|
              expect { described_class.load(value) }.to raise_error(RootMissing) { |e| expect(e.code).to eq("csp_root_missing") }
            end
          end

          it "rejects a bad length or bad hex without printing the value" do
            [secret_hex[0, 62], "#{secret_hex}00", "#{secret_hex[0, 62]}zz"].each do |value|
              expect { described_class.load(value) }.to raise_error(ConfigurationError) { |e| expect_secret_free(e) }
            end
          end

          it "shows the id only in inspect, to_s, pp and as_json" do
            [pin_secret.inspect, pin_secret.to_s, PP.pp(pin_secret, +""), pin_secret.to_json].each do |out|
              expect(out).to include(pin_secret.id)
              expect(out.downcase).not_to include(secret_hex.downcase)
            end
          end

          describe ".voter_key" do
            it "keys a token_csv voter by election and Voter id" do
              uid = "gid://decidim-app/Decidim::Elections::Voter/9"
              expect(described_class.voter_key(election, uid)).to eq("row:42:9")
            end

            it "keys an internal user by election and User id, whatever the app name" do
              expect(described_class.voter_key(election, "gid://decidim-app/Decidim::User/7")).to eq("user:42:7")
              expect(described_class.voter_key(election, "gid://renamed/Decidim::User/7")).to eq("user:42:7")
            end

            it "rejects a foreign or unparsable gid" do
              ["gid://decidim-app/Decidim::Organization/1", "not-a-gid", nil].each do |uid|
                expect { described_class.voter_key(election, uid) }.to raise_error(ArgumentError, "voter_uid")
              end
            end
          end
        end
      end
    end
  end
end
