# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe CspVerifier do
        include_context "with a csp root and chain"

        subject(:verifier) { described_class.new(vocdoni_process) }

        let(:election) { create(:election, :with_internal_users_census) }
        let(:csp_state) { nil }
        let!(:vocdoni_process) do
          create(:vocdoni_process, :published, election:, chain_id: "vocdoni/DEV/36", csp_root_id:, pin_secret_id: csp_pin_secret_id,
                                               census_size: 12, csp_state:)
        end
        let(:seeds) { [SecureRandom.hex(12), SecureRandom.hex(12)] }
        let!(:csp_elections) do
          seeds.map.with_index do |seed, index|
            create(:vocdoni_csp_election, process: vocdoni_process, decidim_question_id: 700 + index, seed:,
                                          census_root: derived_census_root(seed), upstream_id: SecureRandom.hex(32))
          end
        end
        let(:chain_id) { "vocdoni/DEV/36" }
        let(:other_root) { Csp::Crypto.public_key(SecureRandom.random_number(Csp::Crypto::N - 1) + 1).unpack1("H*") }

        before { stub_chain_info(chain_id) }

        def stub_elections(**overrides)
          csp_elections.each { |ce| stub_chain_election(ce.upstream_id, chain_election(ce, **overrides)) }
        end

        describe "#verify_roots!" do
          it "marks the process verified when the chain holds the derived census" do
            stub_elections
            verifier.verify_roots!
            expect(vocdoni_process.reload).to have_attributes(csp_state: "verified", state: "published")
            expect(vocdoni_process.csp_verified_at).to be_present
          end

          it "accepts 0x-prefixed upper-case hex from the chain" do
            csp_elections.each do |ce|
              stub_chain_election(ce.upstream_id, chain_election(ce, census_root: "0x#{ce.census_root.upcase}", organization_id: "0x#{csp_org_hex}"))
            end
            verifier.verify_roots!
            expect(vocdoni_process.reload.csp_state).to eq("verified")
          end

          shared_examples "a compromised process" do |check|
            it "marks the process compromised and names the #{check} check" do
              expect { verifier.verify_roots! }.to raise_error(Csp::Compromised, /#{check}/)
              vocdoni_process.reload
              expect(vocdoni_process.csp_state).to eq("compromised")
              expect(vocdoni_process.csp_verified_at).to be_nil
              expect(vocdoni_process.state).to eq("published")
              expect(vocdoni_process.metadata["last_error"]).to include("step" => "verify_roots", "code" => "csp_compromised")
              expect(vocdoni_process.last_error).to include(check)
            end
          end

          context "when a census root differs" do
            before do
              stub_chain_election(csp_elections.first.upstream_id, chain_election(csp_elections.first))
              stub_chain_election(csp_elections.last.upstream_id, chain_election(csp_elections.last, census_root: other_root))
            end

            it_behaves_like "a compromised process", "root"
          end

          context "when the census origin differs" do
            before { stub_elections(origin: "OFF_CHAIN_CA") }

            it_behaves_like "a compromised process", "origin"
          end

          context "when the census is dynamic" do
            before { stub_elections(dynamic_census: true) }

            it_behaves_like "a compromised process", "dynamic"
          end

          context "when the election is anonymous" do
            before { stub_elections(anonymous: true) }

            it_behaves_like "a compromised process", "anonymous"
          end

          context "when another organization owns the election" do
            before { stub_elections(organization_id: "00000000000000000000000000000000000000ff") }

            it_behaves_like "a compromised process", "org"
          end

          context "when the chain id differs from the one the process was published on" do
            let(:chain_id) { "vocdoni/STAGE/12" }

            before { stub_elections }

            it_behaves_like "a compromised process", "chain_id"
          end

          context "when the root is denied on the production chain" do
            let(:chain_id) { "vocdoni/LTS/1.3" }

            before do
              vocdoni_process.update!(chain_id: "vocdoni/LTS/1.3")
              stub_const("Decidim::Elections::Vocdoni::Csp::Keyring::NON_PROD_ROOT_IDS", [csp_root_id])
              stub_elections
            end

            it_behaves_like "a compromised process", "root_denied"
          end

          it "never logs a census root or the root" do
            stub_elections(census_root: other_root)
            output = StringIO.new
            logger = ActiveSupport::Logger.new(output)
            allow(Rails).to receive(:logger).and_return(logger)
            expect { verifier.verify_roots! }.to raise_error(Csp::Compromised)
            expect(output.string).to include("csp.compromised")
            expect(output.string).not_to include(other_root)
            expect(output.string).not_to include(csp_root.unpack1("H*"))
          end

          context "when the chain size is below the confirmed census size" do
            before do
              stub_elections(max_census_size: 10)
              allow(Rails.logger).to receive(:warn).and_call_original
            end

            it "stays verified, warns and enqueues a resize" do
              expect { verifier.verify_roots! }.to have_enqueued_job(ResizeCensusJob).with(vocdoni_process.id)
              expect(vocdoni_process.reload.csp_state).to eq("verified")
              expect(Rails.logger).to have_received(:warn).with(/csp.size_behind/)
            end
          end

          it "leaves csp_state untouched when the chain cannot be reached" do
            stub_request(:get, "#{csp_chain_url}/chain/info").to_return(status: 503)
            expect { verifier.verify_roots! }.to raise_error(ApiError) { |e| expect(e).to be_transient }
            expect(vocdoni_process.reload.csp_state).to be_nil
          end

          it "waits while an election has no upstream id yet" do
            csp_elections.last.update_columns(upstream_id: nil) # rubocop:disable Rails/SkipsModelValidations
            expect { verifier.verify_roots! }.to raise_error(ApiError) { |e| expect(e).to be_transient }
            expect(vocdoni_process.reload.csp_state).to be_nil
          end

          context "when the process is already compromised" do
            let(:csp_state) { "compromised" }

            it "never turns it verified again" do
              stub_elections
              expect { verifier.verify_roots! }.to raise_error(Csp::Compromised)
              expect(vocdoni_process.reload.csp_state).to eq("compromised")
              expect(a_request(:get, %r{/chain/info})).not_to have_been_made
            end
          end
        end

        describe "#recheck!" do
          let(:csp_state) { "verified" }

          it "keeps a matching process verified" do
            stub_elections
            verifier.recheck!
            expect(vocdoni_process.reload.csp_state).to eq("verified")
          end

          it "flags a changed census root" do
            stub_elections(census_root: other_root)
            expect { verifier.recheck! }.to raise_error(Csp::Compromised, /root/)
            expect(vocdoni_process.reload.csp_state).to eq("compromised")
          end

          it "flags a census that turned dynamic" do
            stub_elections(dynamic_census: true)
            expect { verifier.recheck! }.to raise_error(Csp::Compromised, /dynamic/)
          end

          it "does not resize for an election that no longer takes votes" do
            stub_elections(max_census_size: 1, status: "ENDED")
            expect { verifier.recheck! }.not_to have_enqueued_job(ResizeCensusJob)
          end
        end
      end
    end
  end
end
