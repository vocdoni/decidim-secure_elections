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
              expect(Decidim::Elections::Vocdoni::SyncElectionResultsJob)
                .to receive(:perform_later).with(election.id, mode: :one_shot)
              expect(described_class)
                .to receive(:set).with(wait: described_class::LIVE_CADENCE_S.seconds).and_call_original

              described_class.perform_now(election.id)
            end
          end

          context "and the election has after_end results" do
            it "does not fire SyncElectionResultsJob and reschedules on the idle cadence" do
              expect(Decidim::Elections::Vocdoni::SyncElectionResultsJob)
                .not_to receive(:perform_later)
              expect(described_class)
                .to receive(:set).with(wait: described_class::IDLE_CADENCE_S.seconds).and_call_original

              described_class.perform_now(election.id)
            end
          end
        end

        context "when the SaaS reports ENDED" do
          let(:results_availability) { "real_time" }

          before { stub_saas_get(status: "ENDED") }

          it "stops rescheduling and does not touch the results job" do
            expect(Decidim::Elections::Vocdoni::SyncElectionResultsJob)
              .not_to receive(:perform_later)
            expect(described_class).not_to receive(:set)

            described_class.perform_now(election.id)
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
            expect(Decidim::Elections::Vocdoni::SyncElectionResultsJob)
              .not_to receive(:perform_later)
            expect(described_class)
              .to receive(:set).with(wait: described_class::PUBLISHING_CADENCE_S.seconds).and_call_original

            described_class.perform_now(election.id)
          end
        end
      end
    end
  end
end
