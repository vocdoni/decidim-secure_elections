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

        describe ".active_for?" do
          let(:election) { build(:election) }

          context "when the registry is available and the election uses the :vocdoni backend" do
            before do
              allow(described_class).to receive(:available?).and_return(true)
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

          context "when this Decidim has no voting backend registry" do
            before { allow(described_class).to receive(:available?).and_return(false) }

            it "returns false regardless of backend" do
              expect(described_class.active_for?(election)).to be(false)
            end
          end

          context "when the election uses a different backend" do
            before do
              allow(described_class).to receive(:available?).and_return(true)
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

          it "opts out of live tally when the manifest supports the setting" do
            manifest = Decidim::Elections.voting_backends.find(:vocdoni)
            # Pass when the fork has not added live_tally yet; must be false when it has.
            expect(manifest.live_tally).to be(false) if manifest.respond_to?(:live_tally)
          end

          it "registers the backend as :client transport" do
            manifest = Decidim::Elections.voting_backends.find(:vocdoni)
            expect(manifest.transport).to eq(:client)
            expect(manifest.client?).to be(true)
          end

          it "points the client script at the adapter with a content digest" do
            file = Engine.root.join("public/vocdoni/booth-adapter.js")
            digest = Digest::SHA256.file(file).hexdigest[0, 12]
            manifest = Decidim::Elections.voting_backends.find(:vocdoni)
            expect(manifest.client_script).to eq("/vocdoni/booth-adapter.js?v=#{digest}")
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

          subject(:config) { described_class.booth_config(election, voter_uid: user.to_global_id.to_s) }

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

          it "includes the URL the booth reports a cast to" do
            expect(config[:castNotificationUrl]).to end_with("/elections/#{election.id}/vocdoni_cast_notification")
          end

          it "points the booth at the attestation URL and hands it no credential" do
            expect(config[:attestationUrl]).to end_with("/elections/#{election.id}/vocdoni_attestation")
            expect(config).not_to have_key(:credentials)
          end

          it "never hands the browser the contact itself" do
            expect(config.to_json).not_to include(user.email)
          end

          it "shows no contact without a one-time code" do
            expect(config[:contact]).to eq({})
            expect(config[:i18n][:errors]).not_to have_key(:no_contact)
          end

          it "has no per-question settings" do
            expect(config).not_to have_key(:perQuestion)
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

        describe ".booth_config for a per_question election" do
          let(:election) do
            create(:election, :per_question, :ongoing).tap do |el|
              create(:vocdoni_process, :published, election: el)
            end
          end
          let!(:open) { create(:election_question, :with_response_options, :voting_enabled, election:) }
          let!(:closed) { create(:election_question, :with_response_options, :voting_enabled, :published_results, election:) }
          let!(:idle) { create(:election_question, :with_response_options, election:) }
          let(:user) { create(:user, :confirmed, organization: election.organization) }

          subject(:config) { described_class.booth_config(election, voter_uid: user.to_global_id.to_s) }

          it "offers only the questions the admin has open" do
            expect(config[:questions].pluck(:questionId)).to eq([open.id.to_s])
          end

          it "tells the adapter where to wait for the next question" do
            expect(config[:perQuestion]).to be(true)
            expect(config[:waitingUrl]).to end_with("/elections/#{election.id}/per_question_votes/waiting.json")
            expect(config[:perQuestionI18n]).to include(:waiting, :opening, :not_open)
          end
        end

        describe ".booth_config contact" do
          let(:election) { create(:election, census_manifest:) }
          let(:census_manifest) { "internal_users" }
          let!(:vocdoni_process) do
            create(:vocdoni_process, :published, election:, metadata: { "settings" => { "twofa_fields" => ["email"] } })
          end
          let(:user) { create(:user, :confirmed, organization: election.organization, email: "ada@example.org") }

          def config_for(voter_uid)
            described_class.booth_config(election, voter_uid:)
          end

          it "masks the email of the voter's census entry" do
            expect(config_for(user.to_global_id.to_s)[:contact]).to eq(channel: "email", masked: "a•••@example.org")
          end

          it "explains a missing email" do
            expect(config_for(user.to_global_id.to_s)[:i18n][:errors][:no_contact]).to include("email")
          end

          it "has no contact without a census voter" do
            expect(config_for(nil)[:contact]).to eq(channel: "email")
            expect(config_for(create(:user, :confirmed).to_global_id.to_s)[:contact]).to eq(channel: "email")
          end

          context "with SMS codes" do
            let!(:vocdoni_process) do
              create(:vocdoni_process, :published, election:, metadata: { "settings" => { "twofa_fields" => ["phone"] } })
            end
            let(:census_manifest) { "token_csv" }

            it "masks the E.164 phone of the voter's census entry" do
              voter = create(:election_voter, election:, data: { "email" => "bob@example.org", "phone" => "+34 600 12 34 56" })
              config = config_for(voter.to_global_id.to_s)

              expect(config[:contact]).to eq(channel: "phone", masked: "+•••••••••56")
              expect(config.to_json).not_to include("600123456")
              expect(config[:i18n][:errors][:no_contact]).to include("phone")
            end
          end

          context "with a token_csv census" do
            let(:census_manifest) { "token_csv" }
            let(:voter) do
              create(:election_voter, election:, data: { "email" => "bob@example.org", "token" => "S3CRET" })
            end

            it "reads the CSV row and never exposes its token" do
              config = config_for(voter.to_global_id.to_s)

              expect(config[:contact]).to eq(channel: "email", masked: "b•••@example.org")
              expect(config.to_json).not_to include("S3CRET")
            end
          end
        end
      end
    end
  end
end
