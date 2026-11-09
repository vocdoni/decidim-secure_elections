# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Vocdoni
      describe VotingBackend do
        describe ".available?" do
          it "returns true when the upstream registry exists" do
            expect(described_class.available?).to be(true)
          end
        end

        describe ".enabled?" do
          context "when VOCDONI_INTEGRATED_BOOTH is not set" do
            it "returns true" do
              with_env("VOCDONI_INTEGRATED_BOOTH" => nil) do
                expect(described_class.enabled?).to be(true)
              end
            end
          end

          context "when VOCDONI_INTEGRATED_BOOTH=true" do
            it "returns true" do
              with_env("VOCDONI_INTEGRATED_BOOTH" => "true") do
                expect(described_class.enabled?).to be(true)
              end
            end
          end

          context "when VOCDONI_INTEGRATED_BOOTH=false" do
            it "returns false (rollback switch)" do
              with_env("VOCDONI_INTEGRATED_BOOTH" => "false") do
                expect(described_class.enabled?).to be(false)
              end
            end
          end
        end

        describe ".active_for?" do
          let(:election) { build(:election) }

          context "when the integrated booth is enabled and the election uses the :vocdoni backend" do
            before do
              allow(described_class).to receive(:enabled?).and_return(true)
              vocdoni_manifest = instance_double(
                Decidim::Elections::VotingBackendManifest,
                name: :vocdoni
              )
              allow(election).to receive(:voting_backend).and_return(vocdoni_manifest)
            end

            it "returns true" do
              expect(described_class.active_for?(election)).to be(true)
            end
          end

          context "when the integrated booth is disabled" do
            before { allow(described_class).to receive(:enabled?).and_return(false) }

            it "returns false regardless of backend" do
              expect(described_class.active_for?(election)).to be(false)
            end
          end

          context "when the election uses a different backend" do
            before do
              allow(described_class).to receive(:enabled?).and_return(true)
              other_manifest = instance_double(
                Decidim::Elections::VotingBackendManifest,
                name: :decidim
              )
              allow(election).to receive(:voting_backend).and_return(other_manifest)
            end

            it "returns false" do
              expect(described_class.active_for?(election)).to be(false)
            end
          end
        end

        describe ".register!" do
          it "registers the :vocdoni backend in the upstream registry" do
            # Already registered by the engine initializer; ensure it is there.
            manifest = Decidim::Elections.voting_backends.find(:vocdoni)
            expect(manifest).not_to be_nil
            expect(manifest.name).to eq(:vocdoni)
          end

          it "is idempotent: calling register! twice does not create a duplicate" do
            count_before = Decidim::Elections.voting_backends.manifests.count { |m| m.name == :vocdoni }
            described_class.register!
            count_after = Decidim::Elections.voting_backends.manifests.count { |m| m.name == :vocdoni }
            expect(count_after).to eq(count_before)
          end

          it "registers the backend as :client transport" do
            manifest = Decidim::Elections.voting_backends.find(:vocdoni)
            expect(manifest.transport).to eq(:client)
            expect(manifest.client?).to be(true)
          end

          it "sets supports_per_question to true" do
            manifest = Decidim::Elections.voting_backends.find(:vocdoni)
            expect(manifest.supports_per_question).to be(true)
          end
        end

        describe "manifest voted block" do
          include_context "with concurrency and csp pins"

          let(:organization) { create(:organization) }
          let(:component) { create(:elections_component, organization:) }
          let(:election) do
            create(:election, :ongoing, component:).tap do |el|
              create(:vocdoni_process, :published, election: el)
            end
          end
          let!(:question) { create(:election_question, election:) }
          let(:voter) { create(:user, :confirmed, organization:) }
          let(:voter_uid) { voter.to_global_id.to_s }
          let(:pin_secret_hex) { SecureRandom.hex(32) }

          def vote_for(election, voter_uid, que)
            secret = Vocdoni.csp_pin_secret
            digest = secret.digest(Csp::PinSecret.voter_key(election, voter_uid))
            CspPin.insert!({ # rubocop:disable Rails/SkipsModelValidations
                             process_id: election.vocdoni_process.id,
                             decidim_question_id: que.id,
                             election_id: election.id,
                             csp_root_id: "test",
                             seed: SecureRandom.hex(12),
                             voter_digest: digest,
                             vote_confirmed_at: Time.current
                           })
          end

          around do |example|
            with_env("VOCDONI_CSP_PIN_SECRET" => pin_secret_hex) { example.run }
          end

          subject(:voted) do
            Decidim::Elections.voting_backends.find(:vocdoni).voted?(election, voter_uid)
          end

          it "returns false when the voter has no confirmed pins" do
            expect(voted).to be(false)
          end

          it "returns true when all questions have a confirmed pin for the voter" do
            vote_for(election, voter_uid, question)
            expect(voted).to be(true)
          end

          it "returns false when there are no available questions" do
            allow(election).to receive(:available_questions).and_return([])
            expect(voted).to be(false)
          end

          it "returns false (not an error) when csp_pin_secret is not configured" do
            with_env("VOCDONI_CSP_PIN_SECRET" => nil) do
              expect { voted }.not_to raise_error
              expect(voted).to be(false)
            end
          end

          it "returns false when voter_uid is blank" do
            blank_voted = Decidim::Elections.voting_backends.find(:vocdoni)
                                            .voted?(election, "")
            expect(blank_voted).to be(false)
          end

          context "with two questions" do
            let!(:question2) { create(:election_question, election:) }

            it "returns false when only one of two questions has a confirmed pin" do
              vote_for(election, voter_uid, question)
              expect(voted).to be(false)
            end

            it "returns true when both questions have confirmed pins" do
              vote_for(election, voter_uid, question)
              vote_for(election, voter_uid, question2)
              expect(voted).to be(true)
            end
          end
        end

        describe ".booth_config" do
          let(:organization) { create(:organization) }
          let(:component) { create(:elections_component, organization:) }
          let(:election) do
            create(:election, :ongoing, component:).tap do |el|
              create(:vocdoni_process, :published, election: el)
            end
          end
          let!(:question) { create(:election_question, :with_response_options, election:) }

          subject(:config) { described_class.booth_config(election) }

          it "includes apiUrl from Vocdoni.api_url" do
            expect(config[:apiUrl]).to eq(Decidim::Elections::Vocdoni.api_url)
          end

          it "includes the vocdoni processId when published" do
            process = election.vocdoni_process
            expect(config[:processId]).to eq(process.vocdoni_process_id)
          end

          it "includes the chainId" do
            expect(config[:chainId]).to eq(election.vocdoni_process.chain_id)
          end

          it "does not include credentials or contact" do
            expect(config).not_to have_key(:credentials)
            expect(config).not_to have_key(:contact)
          end

          it "includes signUrl, statusUrl and confirmUrl" do
            expect(config[:signUrl]).to be_a(String)
            expect(config[:statusUrl]).to be_a(String)
            expect(config[:confirmUrl]).to be_a(String)
          end

          it "sets proofType to ECDSA" do
            expect(config[:proofType]).to eq("ECDSA")
          end

          it "reflects perQuestion from the election" do
            expect(config[:perQuestion]).to eq(election.per_question?)
          end

          it "maps questions in the election's question order" do
            expect(config[:questions].length).to eq(1)
            q = config[:questions].first
            expect(q[:questionId]).to eq(question.id.to_s)
          end

          describe "choice ordering matches PublishElectionJob#question_payload" do
            # Both must order response_options by id ascending (consistent idx → value mapping).
            it "maps choices as a hash of option_id => zero-based index ordered by id" do
              options_by_id = question.response_options.order(:id).to_a
              expected = options_by_id.each_with_index.to_h { |option, idx| [option.id.to_s, idx] }
              q = config[:questions].first
              expect(q[:choices]).to eq(expected)
            end
          end

          it "includes i18n keys without :otp" do
            expect(config[:i18n]).to have_key(:status)
            expect(config[:i18n]).to have_key(:errors)
            expect(config[:i18n]).not_to have_key(:otp)
          end
        end
      end
    end
  end
end

# Helper to set environment variables for the duration of a block.
def with_env(vars)
  old = vars.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  vars.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
  yield
ensure
  old.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
end
