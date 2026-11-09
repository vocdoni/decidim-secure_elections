# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe SyncProcessJob do
        let(:api_url) { "https://saas-api.example.org" }
        let(:process_id) { "6885f0c2c1a4e2f0b1d33a01" }
        let(:json_headers) { { "Content-Type" => "application/json" } }
        let(:results_availability) { "after_end" }
        let(:election) { create(:election, results_availability:) }
        let!(:vocdoni_process) do
          create(:vocdoni_process, :published,
                 vocdoni_process_id: process_id,
                 election:)
        end

        def stub_saas_get(status:, published: true)
          stub_request(:get, "#{api_url}/processes/#{process_id}")
            .to_return(
              status: 200,
              body: {
                id: process_id,
                chainId: "vocdoni/LTS/1.2",
                published:,
                questions: [{ id: "q1", status: }]
              }.to_json,
              headers: json_headers
            )
        end

        context "when the SaaS reports an active voting window" do
          before { stub_saas_get(status: "ONGOING") }

          context "and the election has real_time results" do
            let(:results_availability) { "real_time" }

            it "fires a :one_shot SyncElectionResultsJob and reschedules on the live cadence" do
              expect(described_class)
                .to receive(:set).with(wait: described_class::LIVE_CADENCE_S.seconds).and_call_original

              expect { described_class.perform_now(election.id) }
                .to have_enqueued_job(Decidim::Elections::Vocdoni::SyncElectionResultsJob).with(election.id, mode: :one_shot)
            end
          end

          context "and the election has after_end results" do
            it "does not fire SyncElectionResultsJob and reschedules on the idle cadence" do
              expect(described_class)
                .to receive(:set).with(wait: described_class::IDLE_CADENCE_S.seconds).and_call_original

              expect { described_class.perform_now(election.id) }
                .not_to have_enqueued_job(Decidim::Elections::Vocdoni::SyncElectionResultsJob)
            end
          end
        end

        context "when the SaaS reports ENDED" do
          let(:results_availability) { "real_time" }

          before { stub_saas_get(status: "ENDED") }

          it "stops rescheduling and does not touch the results job" do
            expect(described_class).not_to receive(:set)

            expect { described_class.perform_now(election.id) }
              .not_to have_enqueued_job(Decidim::Elections::Vocdoni::SyncElectionResultsJob)
          end
        end

        context "when the sidecar is still publishing" do
          let!(:vocdoni_process) do
            create(:vocdoni_process, :publishing,
                   vocdoni_process_id: process_id,
                   election:)
          end
          let(:results_availability) { "real_time" }

          before { stub_saas_get(status: "READY", published: false) }

          it "reschedules on the publishing cadence and does not fire results-sync" do
            expect(described_class)
              .to receive(:set).with(wait: described_class::PUBLISHING_CADENCE_S.seconds).and_call_original

            expect { described_class.perform_now(election.id) }
              .not_to have_enqueued_job(Decidim::Elections::Vocdoni::SyncElectionResultsJob)
          end
        end

        context "with an external-CSP process" do
          include_context "with a csp root and chain"

          let!(:questions) { create_list(:election_question, 2, :with_response_options, election:) }
          let(:csp_state) { "verified" }
          let!(:vocdoni_process) do
            create(:vocdoni_process, :published, vocdoni_process_id: process_id, election:, chain_id: "vocdoni/DEV/36",
                                                 csp_root_id:, pin_secret_id: csp_pin_secret_id, csp_state:, census_size: 12)
          end
          let!(:csp_elections) do
            questions.map do |question|
              seed = SecureRandom.hex(12)
              create(:vocdoni_csp_election, process: vocdoni_process, decidim_question_id: question.id, seed:,
                                            census_root: derived_census_root(seed), upstream_id: SecureRandom.hex(32))
            end
          end
          let(:saas_census_size) { 12 }

          # SaaS questions in reverse order, each carrying its Decidim id.
          def stub_saas_csp_get
            remote_questions = csp_elections.reverse.map do |ce|
              { id: ce.seed, upstreamId: "0x#{ce.upstream_id}", status: "READY", metadata: { decidimQuestionId: ce.decidim_question_id.to_s } }
            end
            stub_request(:get, "#{api_url}/processes/#{process_id}").to_return(
              json_response({ id: process_id, chainId: "vocdoni/DEV/36", published: true, census: { size: saas_census_size }, questions: remote_questions })
            )
          end

          before do
            stub_chain_info
            stub_saas_csp_get
          end

          it "maps questions by decidimQuestionId and flags a changed root" do
            stub_chain_election(csp_elections.first.upstream_id, chain_election(csp_elections.first))
            other = Csp::Crypto.public_key(SecureRandom.random_number(Csp::Crypto::N - 1) + 1).unpack1("H*")
            stub_chain_election(csp_elections.last.upstream_id, chain_election(csp_elections.last, census_root: other))

            described_class.perform_now(election.id)

            vocdoni_process.reload
            expect(vocdoni_process.csp_state).to eq("compromised")
            expect(vocdoni_process.state).to eq("published")
            expect(vocdoni_process.questions_metadata.to_h { |m| [m["decidim_question_id"], m["vocdoni_question_id"]] })
              .to eq(csp_elections.to_h { |ce| [ce.decidim_question_id, ce.seed] })
          end

          context "when a resize is in flight" do
            let(:saas_census_size) { 20 }

            it "stays verified and keeps the confirmed census size" do
              csp_elections.each { |ce| stub_chain_election(ce.upstream_id, chain_election(ce, max_census_size: 15)) }

              expect { described_class.perform_now(election.id) }.not_to have_enqueued_job(ResizeCensusJob)

              expect(vocdoni_process.reload).to have_attributes(csp_state: "verified", census_size: 12)
            end
          end

          context "when the chain lags behind the confirmed size" do
            it "stays verified and enqueues a resize" do
              csp_elections.each { |ce| stub_chain_election(ce.upstream_id, chain_election(ce, max_census_size: 10)) }

              expect { described_class.perform_now(election.id) }.to have_enqueued_job(ResizeCensusJob).with(vocdoni_process.id)

              expect(vocdoni_process.reload).to have_attributes(csp_state: "verified", census_size: 12)
            end
          end

          context "when the process is not verified yet" do
            let(:csp_state) { nil }

            it "verifies it" do
              csp_elections.each { |ce| stub_chain_election(ce.upstream_id, chain_election(ce)) }
              described_class.perform_now(election.id)
              expect(vocdoni_process.reload.csp_state).to eq("verified")
            end

            it "keeps csp_state nil and records no failure while the chain is down" do
              csp_elections.each { |ce| stub_request(:get, "#{csp_chain_url}/elections/#{ce.upstream_id}").to_return(status: 503) }
              described_class.perform_now(election.id)
              expect(vocdoni_process.reload.csp_state).to be_nil
              expect(vocdoni_process.last_error).to be_nil
              expect(vocdoni_process.state).to eq("published")
            end
          end
        end
      end
    end
  end
end
