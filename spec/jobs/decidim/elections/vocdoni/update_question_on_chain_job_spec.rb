# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe UpdateQuestionOnChainJob do
        let(:api_url) { "https://saas-api.example.org" }
        let(:process_id) { "6885f0c2c1a4e2f0b1d33a01" }
        let(:vocdoni_question_id) { "6885f0c2c1a4e2f0b1d33a02" }
        let(:json_headers) { { "Content-Type" => "application/json" } }
        let(:election) { create(:election, :per_question, :published, :ongoing) }
        let!(:question) { create(:election_question, :with_response_options, :voting_enabled, election:) }
        let(:state) { "published" }
        let!(:vocdoni_process) do
          create(:vocdoni_process, :published,
                 election:, state:, vocdoni_process_id: process_id,
                 metadata: { "questions" => [{ "decidim_question_id" => question.id, "vocdoni_question_id" => vocdoni_question_id }] })
        end

        def vocdoni_fixture(name)
          Decidim::Elections::Vocdoni::Engine.root.join("spec", "fixtures", "vocdoni", "#{name}.json").read
        end

        def stub_status_change(status)
          stub_request(:put, "#{api_url}/processes/#{process_id}/questions/status")
            .with(body: { "status" => status, "questions" => [{ "id" => vocdoni_question_id }] })
            .to_return(status: 200, body: vocdoni_fixture("status_change_enqueued"), headers: json_headers)
        end

        before do
          stub_request(:get, "#{api_url}/jobs/6885f1a3c1a4e2f0b1d33a20")
            .to_return(status: 200, body: vocdoni_fixture("job_completed"), headers: json_headers)
        end

        it "opens only that question on chain when voting is enabled" do
          status_change = stub_status_change("READY")

          expect { described_class.perform_now(question.id, "enable_voting") }
            .not_to have_enqueued_job(SyncElectionResultsJob)

          expect(status_change).to have_been_requested
        end

        it "ends only that question and syncs its tally when its results are published" do
          status_change = stub_status_change("ENDED")

          expect { described_class.perform_now(question.id, "publish_results") }
            .to have_enqueued_job(SyncElectionResultsJob).with(election.id, question_ids: [question.id])

          expect(status_change).to have_been_requested
        end

        it "rejects an unknown action" do
          expect { described_class.perform_now(question.id, "bogus") }.to raise_error(ArgumentError)
        end

        context "when the process is not on chain yet" do
          let(:state) { "publishing" }

          it "leaves the action to PublishElectionJob" do
            described_class.perform_now(question.id, "enable_voting")

            expect(a_request(:any, /saas-api\.example\.org/)).not_to have_been_made
          end
        end

        context "when the SaaS rejects the change" do
          it "records the error without failing the whole process" do
            stub_request(:put, "#{api_url}/processes/#{process_id}/questions/status")
              .to_return(status: 400, body: vocdoni_fixture("error_invalid_body"), headers: json_headers)

            described_class.perform_now(question.id, "enable_voting")

            vocdoni_process.reload
            expect(vocdoni_process.state).to eq("published")
            expect(vocdoni_process.metadata.dig("last_error", "step")).to eq("question_enable_voting")
          end
        end
      end
    end
  end
end
