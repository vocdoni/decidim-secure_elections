# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe SyncResultsAfterVoteJob do
        let(:api_url) { "https://saas-api.example.org" }
        let(:process_id) { "6885f0c2c1a4e2f0b1d33a01" }
        let(:json_headers) { { "Content-Type" => "application/json" } }
        let(:election) { create(:election, results_availability: "real_time") }
        let!(:question) { create(:election_question, :with_response_options, election:) }
        let!(:vocdoni_process) do
          create(:vocdoni_process, :published,
                 vocdoni_process_id: process_id,
                 election:,
                 live_sync_requests: 1,
                 live_sync_until: 1.minute.from_now,
                 synced_vote_count:)
        end
        let(:synced_vote_count) { 1 }

        # The fixture reports `voteCount: 2` and counts `["1", "1"]`.
        before do
          stub_request(:get, "#{api_url}/processes/#{process_id}/results")
            .to_return(
              status: 200,
              body: Decidim::Elections::Vocdoni::Engine.root.join("spec", "fixtures", "vocdoni", "process_results.json").read,
              headers: json_headers
            )
        end

        it "applies the tally and stops once it grew past the last synced total" do
          expect { described_class.perform_now(election.id, seen: 1) }.not_to have_enqueued_job(described_class)

          expect(question.response_options.order(:id).pluck(:votes_count)).to eq([1, 1])
          vocdoni_process.reload
          expect(vocdoni_process.synced_vote_count).to eq(2)
          expect(vocdoni_process.live_sync_until).to be_nil
        end

        context "when the tally has not moved yet" do
          let(:synced_vote_count) { 2 }

          it "checks again on the backoff" do
            expect(described_class).to receive(:set).with(wait: 10.seconds).and_call_original

            expect { described_class.perform_now(election.id, seen: 1, attempt: 2) }
              .to have_enqueued_job(described_class).with(election.id, seen: 1, attempt: 3)
            expect(vocdoni_process.reload.live_sync_until).to be > 10.seconds.from_now
          end

          it "gives up once the backoff runs out" do
            last = SyncElectionResultsJob::POLL_BACKOFF_S.size + 1

            expect { described_class.perform_now(election.id, seen: 1, attempt: last) }.not_to have_enqueued_job(described_class)
            expect(vocdoni_process.reload.live_sync_until).to be_nil
          end
        end

        context "when more votes were reported since the previous check" do
          before { vocdoni_process.update!(live_sync_requests: 4) }

          it "restarts the backoff even though the tally grew" do
            expect(described_class).to receive(:set).with(wait: 5.seconds).and_call_original

            expect { described_class.perform_now(election.id, seen: 1, attempt: 4) }
              .to have_enqueued_job(described_class).with(election.id, seen: 4, attempt: 2)
            expect(vocdoni_process.reload.live_sync_until).to be_present
          end
        end

        context "when a vote is reported between the check and the release" do
          it "keeps the chain alive" do
            allow(LiveResultsSync).to receive(:release!).and_return(false)

            expect { described_class.perform_now(election.id, seen: 1) }
              .to have_enqueued_job(described_class).with(election.id, seen: 1, attempt: 2)
          end
        end
      end
    end
  end
end
