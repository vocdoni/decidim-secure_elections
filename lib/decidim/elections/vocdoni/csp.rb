# frozen_string_literal: true

require "openssl"
require "securerandom"

module Decidim
  module Elections
    module Vocdoni
      # Decidim as the external CSP of a Vocdoni election: it derives one
      # secp256k1 key per on-chain election from a root only it holds and signs
      # each eligible voter's ephemeral address with it (`OFF_CHAIN_CA_V2`,
      # ECDSA proof). The SaaS stores the public keys and never signs.
      module Csp
        # Base class for CSP failures. `code` is the stable string the voter
        # endpoint answers with; messages never carry key material.
        class Error < StandardError
          def code = "csp_error"
        end

        # No root (or no pin secret) is configured, or the root a process was
        # published with is no longer in the keyring. Signing never falls back
        # to another root.
        class RootMissing < Error
          def code = "csp_root_missing"
        end

        # The pin secret differs from the one the process was published with,
        # so every voter digest would change and allow a second pin.
        class PinSecretMismatch < Error
          def code = "pin_secret_mismatch"
        end

        # The database trigger that keeps pins immutable is not installed.
        class TriggerMissing < Error
          def code = "csp_trigger_missing"
        end

        # A malformed CSP setting. A `Vocdoni::ConfigurationError`, so callers
        # of `validate_configuration!` rescue both.
        class ConfigurationError < Vocdoni::ConfigurationError
          def code = "csp_configuration_error"
        end
      end
    end
  end
end

require "decidim/elections/vocdoni/csp/crypto"
require "decidim/elections/vocdoni/csp/keyring"
require "decidim/elections/vocdoni/csp/pin_secret"
