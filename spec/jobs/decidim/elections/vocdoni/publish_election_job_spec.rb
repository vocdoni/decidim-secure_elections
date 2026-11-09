# frozen_string_literal: true

require "spec_helper"

# The SaaS side is the external-CSP contract (create with `census.externalCsp`,
# `PUT /processes/{id}/external-csp`, publish, `GET /processes/{id}`) and the
# chain side the Vochain API, both stubbed with WebMock; the rows land in the
# real test database.
module Decidim
  module Elections
    module Vocdoni
      describe PublishElectionJob do
        include_context "with a csp root and chain"

        let(:api_url) { "https://saas-api.example.org" }
        let(:process_id) { "6885f0c2c1a4e2f0b1d33a01" }
        let(:component) { create(:elections_component) }
        let(:organization) { component.organization }
        let(:election) { create(:election, :with_internal_users_census, component:) }
        let!(:questions) { create_list(:election_question, 2, :with_response_options, election:) }
        let!(:voters) { create_list(:user, 5, :confirmed, organization:) }
        let!(:vocdoni_process) { create(:vocdoni_process, election:) }
        let(:roster) { election.census.count(election) }
        let(:seeds) { { questions.first.id => SecureRandom.hex(12), questions.last.id => SecureRandom.hex(12) } }
        let(:upstream_ids) { { questions.first.id => SecureRandom.hex(32), questions.last.id => SecureRandom.hex(32) } }
        let(:remote_upstream_ids) { upstream_ids }
        let(:chain_id) { "vocdoni/DEV/36" }
        let(:created_bodies) { [] }

        # SaaS questions in reverse order: mapping is by metadata, not position.
        def remote_questions(published:)
          questions.reverse.map do |question|
            q = { id: seeds[question.id], metadata: { decidimQuestionId: question.id.to_s }, status: published ? "READY" : "PENDING" }
            q[:upstreamId] = remote_upstream_ids[question.id] if published
            q
          end
        end

        def remote_process(published:)
          body = { id: process_id, published:, questions: remote_questions(published:) }
          body.merge!(chainId: chain_id, upstreamId: "0x#{"ee" * 32}", census: { size: 999 }) if published
          body
        end

        def expected_roots
          questions.to_h { |q| [seeds[q.id], "0x#{derived_census_root(seeds[q.id])}"] }
        end

        def stub_saas
          stub_request(:post, "#{api_url}/processes").to_return do |request|
            created_bodies << JSON.parse(request.body)
            json_response({ processId: process_id })
          end
          stub_request(:get, "#{api_url}/processes/#{process_id}")
            .to_return(json_response(remote_process(published: false)))
            .then.to_return(json_response(remote_process(published: true)))
          stub_request(:put, "#{api_url}/processes/#{process_id}/external-csp").to_return(status: 204)
          stub_request(:post, "#{api_url}/processes/#{process_id}/publish").to_return(json_response({ jobId: "job-1" }))
          stub_request(:get, "#{api_url}/jobs/job-1").to_return(json_response({ status: "completed" }))
        end

        # The chain is stubbed once the csp elections exist, i.e. after the
        # roots PUT; WebMock answers the election reads from these stubs.
        def stub_chain_after_roots_put
          allow_any_instance_of(ApiClient::Elections).to receive(:set_external_csp_roots).and_wrap_original do |original, *args| # rubocop:disable RSpec/AnyInstance
            original.call(*args).tap do
              vocdoni_process.reload.csp_elections.each do |ce|
                upstream = upstream_ids.fetch(ce.decidim_question_id)
                stub_chain_election(upstream, chain_election(ce, max_census_size: vocdoni_process.reload.census_size).merge(electionId: upstream))
              end
            end
          end
        end

        def chain_election_for(question, **overrides)
          ce = CspElection.find_by(decidim_question_id: question.id)
          chain_election(ce, max_census_size: vocdoni_process.reload.census_size, **overrides)
        end

        before do
          stub_chain_info(chain_id)
        end

        describe "a full publish" do
          before do
            stub_saas
            stub_chain_after_roots_put
          end

          it "declares the census with headroom and maps questions by decidimQuestionId" do
            described_class.perform_now(election.id)

            expect(roster).to be >= 5
            expected_size = Vocdoni.declared_census_size(election, roster)
            census = created_bodies.sole["census"]
            expect(census).to eq("externalCsp" => { "size" => expected_size, "censusUri" => Decidim::ResourceLocatorPresenter.new(election).url })
            expect(created_bodies.sole["questions"].map { |q| q["metadata"] }).to eq(questions.map { |q| { "decidimQuestionId" => q.id.to_s } })

            expect(a_request(:put, "#{api_url}/processes/#{process_id}/external-csp").with(body: { "censusRoots" => expected_roots }))
              .to have_been_made.once
            expect(a_request(:any, %r{/organizations/.*/(members|groups)})).not_to have_been_made
            expect(a_request(:post, %r{/processes/census/validation})).not_to have_been_made

            vocdoni_process.reload
            expect(vocdoni_process).to have_attributes(state: "published", csp_state: "verified", census_size: expected_size,
                                                       csp_root_id:, pin_secret_id: csp_pin_secret_id, chain_id:)
            questions.each do |question|
              ce = vocdoni_process.csp_elections.find_by(decidim_question_id: question.id)
              expect(ce).to have_attributes(seed: seeds[question.id], census_root: derived_census_root(seeds[question.id]),
                                            upstream_id: upstream_ids[question.id])
            end
            expect(vocdoni_process.questions_metadata.to_h { |m| [m["decidim_question_id"], m["vocdoni_question_id"]] })
              .to eq(seeds)
          end

          it "never copies the SaaS census size back" do
            described_class.perform_now(election.id)
            expect(vocdoni_process.reload.census_size).to eq(Vocdoni.declared_census_size(election, roster))
          end

          context "when the SaaS answers 0x-prefixed upper-case upstream ids" do
            let(:remote_upstream_ids) { upstream_ids.transform_values { |id| "0x#{id.upcase}" } }

            it "stores them as 64 lower-case hex" do
              described_class.perform_now(election.id)
              expect(vocdoni_process.reload.csp_elections.pluck(:upstream_id)).to match_array(upstream_ids.values)
            end
          end

          context "when the census is token_csv" do
            let(:election) { create(:election, :with_token_csv_census, component:) }

            it "declares the exact row count" do
              described_class.perform_now(election.id)
              expect(created_bodies.sole.dig("census", "externalCsp", "size")).to eq(3)
            end
          end
        end

        describe "refusals" do
          it "refuses to publish without a CSP root" do
            use_csp_env("VOCDONI_CSP_PIN_SECRET" => csp_pin_secret_hex)
            expect { described_class.perform_now(election.id) }.to raise_error(Csp::RootMissing)
            expect(a_request(:post, "#{api_url}/processes")).not_to have_been_made
            expect(vocdoni_process.reload.metadata["last_error"]).to include("code" => "csp_root_missing", "step" => "csp_ready")
          end

          context "when the chain is production and the root is a non-production one" do
            let(:chain_id) { "vocdoni/LTS/1.3" }

            before { stub_const("Decidim::Elections::Vocdoni::Csp::Keyring::NON_PROD_ROOT_IDS", [csp_root_id]) }

            it "creates nothing" do
              described_class.perform_now(election.id)
              expect(a_request(:post, "#{api_url}/processes")).not_to have_been_made
              expect(vocdoni_process.reload).to have_attributes(csp_root_id: nil, pin_secret_id: nil)
              expect(vocdoni_process.metadata["last_error"]).to include("step" => "record_csp_ids")
            end
          end

          context "when the SaaS question id is not a 12-byte ObjectID" do
            before do
              seeds[questions.first.id] = SecureRandom.hex(12)[0, 23]
              stub_saas
            end

            it "stores no roots and records the failure" do
              described_class.perform_now(election.id)
              expect(a_request(:put, %r{/external-csp})).not_to have_been_made
              expect(a_request(:post, %r{/publish})).not_to have_been_made
              expect(vocdoni_process.reload.metadata["last_error"]).to include("code" => "csp_integrity", "step" => "csp_elections")
            end
          end

          it "refuses an empty census" do
            Decidim::User.where(organization:).find_each { |u| u.update_columns(confirmed_at: nil) } # rubocop:disable Rails/SkipsModelValidations
            described_class.perform_now(election.id)
            expect(a_request(:post, "#{api_url}/processes")).not_to have_been_made
            expect(vocdoni_process.reload.last_error).to include("empty census")
          end

          context "when the SaaS reports a different upstream id than the recorded one" do
            let(:recorded) { SecureRandom.hex(32) }

            before do
              vocdoni_process.update!(state: "failed", vocdoni_process_id: process_id, census_size: 6, csp_root_id:, pin_secret_id: csp_pin_secret_id)
              questions.each do |q|
                create(:vocdoni_csp_election, process: vocdoni_process, decidim_question_id: q.id, seed: seeds[q.id],
                                              census_root: derived_census_root(seeds[q.id]),
                                              upstream_id: q == questions.first ? recorded : nil)
              end
              stub_request(:get, "#{api_url}/processes/#{process_id}").to_return(json_response(remote_process(published: true)))
            end

            it "keeps the recorded id and records the failure" do
              described_class.perform_now(election.id)
              expect(CspElection.find_by(decidim_question_id: questions.first.id).upstream_id).to eq(recorded)
              expect(vocdoni_process.reload.metadata["last_error"]).to include("code" => "csp_integrity", "step" => "persist")
              expect(vocdoni_process.csp_state).to be_nil
            end
          end
        end

        describe "verification after publish" do
          before { stub_saas }

          it "marks the process compromised when the chain holds another root" do
            allow_any_instance_of(ApiClient::Elections).to receive(:set_external_csp_roots).and_wrap_original do |original, *args| # rubocop:disable RSpec/AnyInstance
              original.call(*args).tap do
                other = Csp::Crypto.public_key(SecureRandom.random_number(Csp::Crypto::N - 1) + 1).unpack1("H*")
                questions.each { |q| stub_chain_election(upstream_ids[q.id], chain_election_for(q, census_root: other)) }
              end
            end

            expect { described_class.perform_now(election.id) }.not_to raise_error
            expect(vocdoni_process.reload).to have_attributes(state: "published", csp_state: "compromised")
            expect(vocdoni_process.metadata["last_error"]).to include("code" => "csp_compromised")
          end

          it "leaves csp_state nil when the chain is down and verifies on a later sync tick" do
            questions.each do |q|
              stub_request(:get, "#{csp_chain_url}/elections/#{upstream_ids[q.id]}").to_return(status: 503)
            end
            described_class.perform_now(election.id)
            expect(vocdoni_process.reload).to have_attributes(state: "published", csp_state: nil)

            stub_request(:get, "#{api_url}/processes/#{process_id}").to_return(json_response(remote_process(published: true)))
            questions.each { |q| stub_chain_election(upstream_ids[q.id], chain_election_for(q)) }
            SyncProcessJob.perform_now(election.id)
            expect(vocdoni_process.reload.csp_state).to eq("verified")
          end
        end
      end
    end
  end
end
