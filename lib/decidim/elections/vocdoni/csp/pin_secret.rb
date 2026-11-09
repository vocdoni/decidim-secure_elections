# frozen_string_literal: true

require "globalid"

module Decidim
  module Elections
    module Vocdoni
      module Csp
        # HMAC key that turns a voter into the digest their pins are stored
        # under (`VOCDONI_CSP_PIN_SECRET`, 64 hex chars). It is separate from the
        # keyring so that adding a root changes no digest, and it must equal no
        # root. Lives only in memory: `inspect`, `to_s`, `as_json` and every
        # error message show the id only.
        class PinSecret
          FORMAT = /\A\h{64}\z/

          def self.load(value)
            raise RootMissing, "VOCDONI_CSP_PIN_SECRET is not set" if value.to_s.strip.empty?
            raise ConfigurationError, "VOCDONI_CSP_PIN_SECRET must be 64 hex characters" unless FORMAT.match?(value.to_s.strip)

            new([value.to_s.strip].pack("H*"))
          end

          # The per-election identity of a voter, from the `voter_uid` GlobalID
          # the census hands out. Keyed on the model id rather than the GlobalID
          # string, which embeds the app name.
          def self.voter_key(election, voter_uid)
            gid = GlobalID.parse(voter_uid)
            raise ArgumentError, "voter_uid" unless gid

            case gid.model_name
            when "Decidim::Elections::Voter" then "row:#{election.id}:#{gid.model_id}"
            when "Decidim::User" then "user:#{election.id}:#{gid.model_id}"
            else raise ArgumentError, "voter_uid"
            end
          end

          attr_reader :id

          def initialize(secret)
            @secret = secret.b.freeze
            @id = Crypto.keccak(@secret)[0, 8].unpack1("H*").freeze
            freeze
          end

          def digest(voter_key) = OpenSSL::HMAC.hexdigest("SHA256", @secret, voter_key.to_s)

          def assert_separate!(keyring)
            return true unless keyring.include_root?(@secret)

            raise ConfigurationError, "VOCDONI_CSP_PIN_SECRET (#{id}) equals a CSP root"
          end

          def inspect = "#<#{self.class.name} id=#{id}>"
          alias to_s inspect

          def pretty_print(pp) = pp.text(inspect)

          def as_json(*) = { "id" => id }
        end
      end
    end
  end
end
