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
        def stub_live_statuses(*statuses)
          remote = JSON.parse(vocdoni_fixture("process"))
          first = remote["questions"].first
          remote["questions"] = statuses.each_with_index.map { |status, i| first.merge("id" => "q-#{i}", "status" => status) }
          stub_request(:get, "#{api_url}/processes/#{process_id}")
            .to_return(status: 200, body: remote.to_json, headers: json_headers)
        end

        before do
          stub_request(:get, "#{api_url}/jobs/6885f1a3c1a4e2f0b1d33a20")
            .to_return(status: 200, body: vocdoni_fixture("job_completed"), headers: json_headers)
          stub_live_statuses("ONGOING")
        end

        context "when the chain already ended every question" do
          before { stub_live_statuses("ENDED", "RESULTS") }

          it "sends no move and finishes as on success" do
            vocdoni_process.record_pending_action!("end", since: 20.minutes.ago.iso8601, attempts: 61, gave_up: true)

            expect { described_class.perform_now(election.id) }
              .to have_enqueued_job(Decidim::Elections::Vocdoni::SyncProcessJob).with(election.id)
              .and have_enqueued_job(Decidim::Elections::Vocdoni::SyncElectionResultsJob).with(election.id)

            expect(a_request(:put, "#{api_url}/processes/#{process_id}/questions/status")).not_to have_been_made
            expect(vocdoni_process.reload.pending_actions).to be_empty
          end
        end

        it "moves every question on chain to ENDED and chains the two syncs" do
          status_change = stub_request(:put, "#{api_url}/processes/#{process_id}/questions/status")
                          .with(body: { "status" => "ENDED" })
                          .to_return(status: 200, body: vocdoni_fixture("status_change_enqueued"), headers: json_headers)

          expect { described_class.perform_now(election.id) }
            .to have_enqueued_job(Decidim::Elections::Vocdoni::SyncProcessJob).with(election.id)
            .and have_enqueued_job(Decidim::Elections::Vocdoni::SyncElectionResultsJob).with(election.id)

          expect(status_change).to have_been_requested
        end

        context "with a per_question election whose questions end one by one" do
          let!(:vocdoni_process) do
            create(:vocdoni_process, :published, vocdoni_process_id: process_id,
                                                 election: create(:election, :per_question))
          end

          before do
            remote = JSON.parse(vocdoni_fixture("process"))
            first = remote["questions"].first
            remote["questions"] = [
              first.merge("id" => "q-ended", "status" => "ENDED"),
              first.merge("id" => "q-paused", "status" => "PAUSED")
            ]
            stub_request(:get, "#{api_url}/processes/#{process_id}")
              .to_return(status: 200, body: remote.to_json, headers: json_headers)
          end

          it "ends only the questions that are still open or paused" do
            status_change = stub_request(:put, "#{api_url}/processes/#{process_id}/questions/status")
                            .with(body: { "status" => "ENDED", "questions" => [{ "id" => "q-paused" }] })
                            .to_return(status: 200, body: vocdoni_fixture("status_change_enqueued"), headers: json_headers)

            described_class.perform_now(election.id)

            expect(status_change).to have_been_requested
          end
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

        describe "a busy organization" do
          let(:pending) { vocdoni_process.reload.pending_actions["end"] }

          def stub_busy(status: 503, body: { error: "another transaction for this organization is in progress", code: 50_303 }.to_json)
            stub_request(:put, "#{api_url}/processes/#{process_id}/questions/status")
              .to_return(status:, body:, headers: json_headers)
          end

          def within_jitter(base)
            a_value_between((base * 0.8).seconds.from_now - 1.second, (base * 1.2).seconds.from_now + 1.second)
          end

          it "reschedules itself without failing anything" do
            stub_busy

            expect { described_class.perform_now(election.id) }
              .to have_enqueued_job(described_class)
              .with(election.id, busy: { "since" => kind_of(String), "attempts" => 1 })
              .at(within_jitter(2))

            vocdoni_process.reload
            expect(vocdoni_process).to be_published
            expect(vocdoni_process.last_error).to be_nil
            expect(vocdoni_process.metadata).not_to have_key("last_error")
            expect(pending).to include("attempts" => 1)
            expect(pending["next_in"]).to be_between(2, 3)
            expect(SyncProcessJob).not_to have_been_enqueued
          end

          it "treats the proxy's HTML 504 as busy and waits 15 s after the third try" do
            stub_busy(status: 504, body: "<html>Gateway Timeout</html>")
            since = 1.minute.ago.iso8601

            expect { described_class.perform_now(election.id, busy: { since:, attempts: 3 }) }
              .to have_enqueued_job(described_class)
              .with(election.id, busy: { "since" => since, "attempts" => 4 })
              .at(within_jitter(15))

            expect(pending).to include("since" => since, "attempts" => 4)
          end

          it "gives up after 15 minutes and leaves the rest to the sync" do
            stub_busy

            expect { described_class.perform_now(election.id, busy: { "since" => 16.minutes.ago.iso8601, "attempts" => 60 }) }
              .not_to have_enqueued_job(described_class)

            expect(pending).to include("attempts" => 61, "gave_up" => true)
            expect(vocdoni_process.state).to eq("published")
            expect(vocdoni_process.last_error).to be_nil
          end

          it "keeps a given-up action given up on a fresh run" do
            vocdoni_process.record_pending_action!("end", since: 30.minutes.ago.iso8601, attempts: 61, gave_up: true)
            stub_busy

            expect { described_class.perform_now(election.id) }.not_to have_enqueued_job(described_class)

            expect(pending).to include("attempts" => 62, "gave_up" => true)
          end

          it "clears the pending entry once the questions end" do
            vocdoni_process.record_pending_action!("end", since: 1.minute.ago.iso8601, attempts: 2)
            stub_request(:put, "#{api_url}/processes/#{process_id}/questions/status")
              .to_return(status: 200, body: vocdoni_fixture("status_change_enqueued"), headers: json_headers)

            described_class.perform_now(election.id, busy: { "since" => 1.minute.ago.iso8601, "attempts" => 2 })

            expect(vocdoni_process.reload.pending_actions).to be_empty
          end
        end

        # The election is ended in Decidim; a failed move must not hide it (#84).
        describe "a failed move" do
          it "records the error and keeps the process published" do
            stub_request(:put, "#{api_url}/processes/#{process_id}/questions/status")
              .to_return(status: 400, body: vocdoni_fixture("error_invalid_body"), headers: json_headers)

            described_class.perform_now(election.id)

            vocdoni_process.reload
            expect(vocdoni_process).to be_published
            expect(vocdoni_process.metadata.dig("last_error", "step")).to eq("end_on_chain")
          end

          it "keeps the process published while retrying a transient error" do
            stub_request(:put, "#{api_url}/processes/#{process_id}/questions/status")
              .to_return(status: 500, body: vocdoni_fixture("error_invalid_body"), headers: json_headers)

            expect { described_class.perform_now(election.id) }.to have_enqueued_job(described_class).with(election.id)

            expect(vocdoni_process.reload).to be_published
          end
        end
      end
    end
  end
end
