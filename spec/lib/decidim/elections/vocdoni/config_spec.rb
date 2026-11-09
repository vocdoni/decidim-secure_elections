# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    describe Vocdoni do
      let(:csp_vars) do
        %w(VOCDONI_CSP_ROOTS VOCDONI_CSP_PIN_SECRET VOCDONI_CHAIN_API_URL VOCDONI_CENSUS_HEADROOM
           VOCDONI_CSP_BOOT_CHECK VOCDONI_EXTERNAL_CSP_ORIGIN)
      end
      let(:root) { Vocdoni::Csp::Crypto.i2b(SecureRandom.random_number(Vocdoni::Csp::Crypto::N - 1) + 1) }
      let(:root_id) { Vocdoni::Csp::Keyring.id_for(root) }
      let(:roots_env) { "#{root_id}:#{root.unpack1("H*")}" }
      let(:secret_hex) { SecureRandom.hex(32) }
      let(:production) { ActiveSupport::EnvironmentInquirer.new("production") }

      # Runs the block with only the given CSP variables set.
      def with_csp_env(vars = {})
        old = csp_vars.index_with { |k| ENV.fetch(k, nil) }
        csp_vars.each { |k| ENV.delete(k) }
        vars.each { |k, v| ENV[k] = v }
        described_class.reset_csp!
        yield
      ensure
        old.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
        described_class.reset_csp!
      end

      describe ".census_headroom" do
        it "defaults to 1/5 as a Rational" do
          with_csp_env do
            expect(described_class.census_headroom).to eq(Rational(1, 5))
            expect(described_class.census_headroom).to be_a(Rational)
          end
        end

        it "accepts the bounds 0 and 1" do
          with_csp_env("VOCDONI_CENSUS_HEADROOM" => "0") { expect(described_class.census_headroom).to eq(0) }
          with_csp_env("VOCDONI_CENSUS_HEADROOM" => "1") { expect(described_class.census_headroom).to eq(1) }
        end

        it "rejects values that do not parse or fall outside [0, 1]" do
          %w(-0.1 1.5 abc).each do |value|
            with_csp_env("VOCDONI_CENSUS_HEADROOM" => value) do
              expect { described_class.census_headroom }
                .to raise_error(Vocdoni::ConfigurationError, /VOCDONI_CENSUS_HEADROOM/)
            end
          end
        end
      end

      describe ".chain_api_url" do
        it "strips a trailing slash" do
          with_csp_env("VOCDONI_CHAIN_API_URL" => "https://api.example.org/v2/") do
            expect(described_class.chain_api_url).to eq("https://api.example.org/v2")
          end
        end

        it "defaults to the dev chain outside production" do
          with_csp_env { expect(described_class.chain_api_url).to eq("https://api-dev.vocdoni.net/v2") }
        end

        it "has no default in production" do
          allow(Rails).to receive(:env).and_return(production)
          with_csp_env do
            expect { described_class.chain_api_url }.to raise_error(Vocdoni::ConfigurationError, /VOCDONI_CHAIN_API_URL/)
          end
        end
      end

      describe ".csp_origin" do
        it "defaults to OFF_CHAIN_CA_V2" do
          described_class.csp_origin = nil
          with_csp_env { expect(described_class.csp_origin).to eq("OFF_CHAIN_CA_V2") }
        end
      end

      describe ".lts_chain_id?" do
        it "is true only for vocdoni/LTS/ chain ids" do
          expect(described_class.lts_chain_id?("vocdoni/LTS/1.3")).to be(true)
          expect(described_class.lts_chain_id?("vocdoni/DEV/36")).to be(false)
          expect(described_class.lts_chain_id?("vocdoni/STAGE/12")).to be(false)
          expect(described_class.lts_chain_id?(nil)).to be(false)
        end
      end

      describe ".csp_ready!" do
        it "raises RootMissing with no roots" do
          with_csp_env("VOCDONI_CSP_PIN_SECRET" => secret_hex) do
            expect { described_class.csp_ready! }
              .to raise_error(Vocdoni::Csp::RootMissing) { |e| expect(e.code).to eq("csp_root_missing") }
          end
        end

        it "raises RootMissing with no pin secret" do
          with_csp_env("VOCDONI_CSP_ROOTS" => roots_env) do
            expect { described_class.csp_ready! }.to raise_error(Vocdoni::Csp::RootMissing)
          end
        end

        it "returns with valid roots and secret and does not re-run the checks" do
          with_csp_env("VOCDONI_CSP_ROOTS" => roots_env, "VOCDONI_CSP_PIN_SECRET" => secret_hex) do
            expect(described_class).to receive(:csp_checks!).once.and_call_original
            expect(described_class.csp_ready!).to be(true)
            expect(described_class.csp_ready!).to be(true)
          end
        end

        it "keeps the keyring and the pin secret separate objects and variables" do
          with_csp_env("VOCDONI_CSP_ROOTS" => roots_env, "VOCDONI_CSP_PIN_SECRET" => secret_hex) do
            expect(described_class.csp_keyring.ids).to eq([root_id])
            expect(described_class.csp_pin_secret.id).not_to eq(root_id)
          end
        end

        it "refuses a pin secret equal to a root" do
          with_csp_env("VOCDONI_CSP_ROOTS" => roots_env, "VOCDONI_CSP_PIN_SECRET" => root.unpack1("H*")) do
            expect { described_class.csp_ready! }
              .to raise_error(Vocdoni::Csp::ConfigurationError) { |e| expect(e.message).not_to include(root.unpack1("H*")) }
          end
        end

        it "refuses a bad census headroom" do
          with_csp_env("VOCDONI_CSP_ROOTS" => roots_env, "VOCDONI_CSP_PIN_SECRET" => secret_hex,
                       "VOCDONI_CENSUS_HEADROOM" => "2") do
            expect { described_class.csp_ready! }.to raise_error(Vocdoni::Csp::ConfigurationError)
          end
        end

        it "refuses an OpenSSL without Keccak-256" do
          env = { "VOCDONI_CSP_ROOTS" => roots_env, "VOCDONI_CSP_PIN_SECRET" => secret_hex }
          allow(OpenSSL::Digest).to receive(:new).and_call_original
          allow(OpenSSL::Digest).to receive(:new).with("KECCAK-256").and_raise(RuntimeError, "Unsupported digest algorithm")
          with_csp_env(env) do
            expect { described_class.csp_ready! }.to raise_error(Vocdoni::Csp::ConfigurationError, /OpenSSL >= 3.2/)
          end
        end

        it "refuses an OpenSSL that answers SHA3-256 for Keccak-256" do
          env = { "VOCDONI_CSP_ROOTS" => roots_env, "VOCDONI_CSP_PIN_SECRET" => secret_hex }
          sha3 = OpenSSL::Digest.new("SHA3-256")
          allow(OpenSSL::Digest).to receive(:new).and_call_original
          allow(OpenSSL::Digest).to receive(:new).with("KECCAK-256").and_return(sha3)
          with_csp_env(env) do
            expect { described_class.csp_ready! }.to raise_error(Vocdoni::Csp::ConfigurationError, /OpenSSL >= 3.2/)
          end
        end

        it "requires the chain API URL in production" do
          allow(Rails).to receive(:env).and_return(production)
          with_csp_env("VOCDONI_CSP_ROOTS" => roots_env, "VOCDONI_CSP_PIN_SECRET" => secret_hex) do
            expect { described_class.csp_ready! }.to raise_error(Vocdoni::Csp::ConfigurationError, /VOCDONI_CHAIN_API_URL/)
          end
        end
      end

      describe "csp_boot after_initialize hook" do
        let(:logger) { instance_double(ActiveSupport::Logger, info: nil, warn: nil) }

        # Runs the engine's `csp_boot` initializer against a stand-in app, then
        # the after_initialize block it registers.
        def run_csp_boot
          initializer = Vocdoni::Engine.instance.initializers.find { |i| i.name == "decidim_elections_vocdoni.csp_boot" }
          blocks = []
          config = Struct.new(:blocks) { def after_initialize(&block) = blocks << block }.new(blocks)
          initializer.run(Struct.new(:config).new(config))
          expect(blocks.size).to eq(1)
          blocks.each(&:call)
        end

        before do
          allow(Rails).to receive(:env).and_return(production)
          allow(Rails).to receive(:logger).and_return(logger)
          allow(Rails).to receive(:const_defined?).and_call_original
          allow(Rails).to receive(:const_defined?).with(:Server, false).and_return(false)
          allow(::Sidekiq).to receive(:server?).and_return(false) if defined?(::Sidekiq)
        end

        it "does nothing outside a serving process, even in production with no CSP variables" do
          with_csp_env do
            expect(described_class).not_to receive(:csp_ready!)
            expect { run_csp_boot }.not_to raise_error
          end
        end

        it "raises RootMissing in production when VOCDONI_CSP_BOOT_CHECK=1" do
          with_csp_env("VOCDONI_CSP_BOOT_CHECK" => "1") do
            expect { run_csp_boot }.to raise_error(Vocdoni::Csp::RootMissing)
          end
        end

        it "runs under rails server" do
          allow(Rails).to receive(:const_defined?).with(:Server, false).and_return(true)
          with_csp_env do
            expect { run_csp_boot }.to raise_error(Vocdoni::Csp::RootMissing)
          end
        end

        it "warns instead of raising outside production" do
          allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("development"))
          with_csp_env("VOCDONI_CSP_BOOT_CHECK" => "1") do
            expect { run_csp_boot }.not_to raise_error
            expect(logger).to have_received(:warn).with(/csp_root_missing|RootMissing/)
          end
        end

        it "logs the root and pin secret ids, never the keys, when ready" do
          with_csp_env("VOCDONI_CSP_BOOT_CHECK" => "1", "VOCDONI_CSP_ROOTS" => roots_env,
                       "VOCDONI_CSP_PIN_SECRET" => secret_hex, "VOCDONI_CHAIN_API_URL" => "https://api.example.org/v2") do
            run_csp_boot
            pin_id = described_class.csp_pin_secret.id
            expect(logger).to have_received(:info).with("[vocdoni] CSP ready csp_root_id=#{root_id} pin_secret_id=#{pin_id}")
          end
        end
      end
    end
  end
end
