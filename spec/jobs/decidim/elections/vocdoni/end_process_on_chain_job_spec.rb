# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe EndProcessOnChainJob do
        let(:api_url) { "https://saas-api.example.org" }
        let(:process_id) { "6885f0c2c1a4e2f0b1d33a01" }
        let(:json_headers) { { "Content-Type" => "application/json" } }
        let!(:vocdoni_process) do
          create(:vocdoni_process, :published, vocdoni_process_id: process_id)
        end
        let(:election) { vocdoni_process.election }

        def vocdoni_fixture(name)
          Decidim::Elections::Vocdoni::Engine.root.join("spec", "fixtures", "vocdoni", "#{name}.json").read
        end

        # `ApiClient::Jobs#wait_for` only accepts `status == "completed"` as
        # success — anything else keeps it polling until the timeout, and the
        # timeout is what surfaces as an ApiError back into `retry_on`. Reuse
        # the same shape the fixture already ships with.
        before do
          stub_request(:get, "#{api_url}/jobs/6885f1a3c1a4e2f0b1d33a20")
            .to_return(status: 200, body: vocdoni_fixture("job_completed"), headers: json_headers)
        end

        it "moves every question on chain to ENDED and chains the two syncs" do
          status_change = stub_request(:put, "#{api_url}/processes/#{process_id}/questions/status")
                          .with(body: { "status" => "ENDED" })
                          .to_return(status: 200, body: vocdoni_fixture("status_change_enqueued"), headers: json_headers)

          expect(Decidim::Elections::Vocdoni::SyncProcessJob).to receive(:perform_later).with(election.id)
          expect(Decidim::Elections::Vocdoni::SyncElectionResultsJob).to receive(:perform_later).with(election.id)

          described_class.perform_now(election.id)

          expect(status_change).to have_been_requested
        end

        context "when the sidecar is missing" do
          let!(:vocdoni_process) { nil }
          let(:election) { create(:election) }

          it "does not touch the SaaS" do
            described_class.perform_now(election.id)

            expect(a_request(:any, /saas-api\.example\.org/)).not_to have_been_made
          end
        end

        context "when the process is not yet published on chain" do
          let!(:vocdoni_process) do
            create(:vocdoni_process, :publishing, vocdoni_process_id: process_id)
          end

          it "does not touch the SaaS" do
            described_class.perform_now(election.id)

            expect(a_request(:any, /saas-api\.example\.org/)).not_to have_been_made
          end
        end
      end
    end
  end
end
