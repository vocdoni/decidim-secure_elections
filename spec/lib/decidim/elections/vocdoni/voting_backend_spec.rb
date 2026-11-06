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
          let(:user) { create(:user, :confirmed, organization:) }

          subject(:config) { described_class.booth_config(election, user) }

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

          it "sets credentials.memberNumber to user.id.to_s" do
            expect(config[:credentials]).to eq(memberNumber: user.id.to_s)
          end

          it "sets contact.email to the user's email" do
            expect(config[:contact][:email]).to eq(user.email)
          end

          it "includes a masked contact email" do
            expect(config[:contact][:masked]).to be_a(String)
            expect(config[:contact][:masked]).to include("•••@")
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
        end
      end
    end
  end
end

# Helper to set environment variables for the duration of a block.
def with_env(vars)
  old = vars.to_h { |k, _| [k, ENV[k]] }
  vars.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
  yield
ensure
  old.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
end
