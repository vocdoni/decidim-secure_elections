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
        let(:question_traits) { [:voting_enabled] }
        let!(:question) { create(:election_question, :with_response_options, *question_traits, election:) }
        let(:state) { "published" }
        let(:cached_status) { nil }
        let!(:vocdoni_process) do
          create(:vocdoni_process, :published,
                 election:, state:, vocdoni_process_id: process_id,
                 metadata: { "questions" => [{ "decidim_question_id" => question.id,
                                               "vocdoni_question_id" => vocdoni_question_id,
                                               "vocdoni_status" => cached_status }.compact] })
        end

        def vocdoni_fixture(name)
          Decidim::Elections::Vocdoni::Engine.root.join("spec", "fixtures", "vocdoni", "#{name}.json").read
        end

        def stub_status_change(status)
          stub_request(:put, "#{api_url}/processes/#{process_id}/questions/status")
            .with(body: { "status" => status, "questions" => [{ "id" => vocdoni_question_id }] })
            .to_return(status: 200, body: vocdoni_fixture("status_change_enqueued"), headers: json_headers)
        end

        def stub_status_rejected(http_status = 400)
          stub_request(:put, "#{api_url}/processes/#{process_id}/questions/status")
            .to_return(status: http_status, body: vocdoni_fixture("error_invalid_body"), headers: json_headers)
        end

        def stub_live_status(status)
          remote = JSON.parse(vocdoni_fixture("process"))
          remote["questions"] = [remote["questions"].first.merge("id" => vocdoni_question_id, "status" => status)]
          stub_request(:get, "#{api_url}/processes/#{process_id}")
            .to_return(status: 200, body: remote.to_json, headers: json_headers)
        end

        before do
          stub_request(:get, "#{api_url}/jobs/6885f1a3c1a4e2f0b1d33a20")
            .to_return(status: 200, body: vocdoni_fixture("job_completed"), headers: json_headers)
        end

        it "rejects an unknown action" do
          expect { described_class.perform_now(question.id, "bogus") }.to raise_error(ArgumentError)
        end

        context "when voting is enabled" do
          before { stub_live_status("PAUSED") }

          it "opens only that question on chain" do
            status_change = stub_status_change("READY")

            expect { described_class.perform_now(question.id, "enable_voting") }
              .not_to have_enqueued_job(SyncElectionResultsJob)

            expect(status_change).to have_been_requested
          end
        end

        context "when the results are published" do
          let(:question_traits) { [:voting_enabled, :published_results] }

          before { stub_live_status("READY") }

          it "ends only that question and syncs its tally" do
            status_change = stub_status_change("ENDED")

            expect { described_class.perform_now(question.id, "publish_results") }
              .to have_enqueued_job(SyncElectionResultsJob).with(election.id, question_ids: [question.id])

            expect(status_change).to have_been_requested
          end
        end

        context "when the process is not on chain yet" do
          let(:state) { "publishing" }

          it "checks again shortly instead of calling the SaaS" do
            expect { described_class.perform_now(question.id, "enable_voting") }
              .to have_enqueued_job(described_class)
              .with(question.id, "enable_voting", publish_wait: 1)
              .at(a_value_within(2.seconds).of(described_class::PUBLISH_WAIT_S.seconds.from_now))

            expect(a_request(:any, /saas-api\.example\.org/)).not_to have_been_made
          end

          it "stops checking after the wait budget and leaves the action to PublishElectionJob" do
            expect { described_class.perform_now(question.id, "enable_voting", publish_wait: described_class::PUBLISH_WAIT_ATTEMPTS) }
              .not_to have_enqueued_job(described_class)
          end

          it "does not wait for an action Decidim has moved past" do
            question.update!(voting_enabled_at: nil)

            expect { described_class.perform_now(question.id, "enable_voting") }
              .not_to have_enqueued_job(described_class)
          end

          context "when the publish lands while the job waits" do
            before { stub_live_status("PAUSED") }

            it "opens the question on the next check" do
              status_change = stub_status_change("READY")
              described_class.perform_now(question.id, "enable_voting")

              vocdoni_process.update!(state: "published")
              described_class.perform_now(question.id, "enable_voting", publish_wait: 1)

              expect(status_change).to have_been_requested.once
            end
          end
        end

        context "when the process is waiting for a scheduled publish" do
          let(:state) { "pending" }

          it "leaves the action to PublishElectionJob" do
            expect { described_class.perform_now(question.id, "enable_voting") }
              .not_to have_enqueued_job(described_class)

            expect(a_request(:any, /saas-api\.example\.org/)).not_to have_been_made
          end
        end

        describe "a stale action" do
          context "when enable_voting runs after the results were published" do
            let(:question_traits) { [:voting_enabled, :published_results] }

            it "does nothing" do
              expect { described_class.perform_now(question.id, "enable_voting") }
                .not_to have_enqueued_job

              expect(a_request(:any, /saas-api\.example\.org/)).not_to have_been_made
            end
          end

          context "when publish_results runs for a question whose results are not published" do
            it "does nothing" do
              expect { described_class.perform_now(question.id, "publish_results") }
                .not_to have_enqueued_job

              expect(a_request(:any, /saas-api\.example\.org/)).not_to have_been_made
            end
          end
        end

        describe "the live chain status" do
          context "when the question is already READY" do
            before { stub_live_status("READY") }

            it "skips the move and the results sync for enable_voting" do
              status_change = stub_status_change("READY")

              expect { described_class.perform_now(question.id, "enable_voting") }
                .not_to have_enqueued_job(SyncElectionResultsJob)

              expect(status_change).not_to have_been_requested
            end
          end

          context "when the question is already ENDED" do
            let(:question_traits) { [:voting_enabled, :published_results] }

            before { stub_live_status("ENDED") }

            it "skips the move but still syncs the tally" do
              status_change = stub_status_change("ENDED")

              expect { described_class.perform_now(question.id, "publish_results") }
                .to have_enqueued_job(SyncElectionResultsJob).with(election.id, question_ids: [question.id])

              expect(status_change).not_to have_been_requested
            end
          end

          context "when the question is ENDED on chain but still enabled in Decidim" do
            before { stub_live_status("ENDED") }

            it "never reopens it" do
              status_change = stub_status_change("READY")

              described_class.perform_now(question.id, "enable_voting")

              expect(status_change).not_to have_been_requested
            end
          end

          context "when the cached status is stale" do
            let(:cached_status) { "READY" }

            before { stub_live_status("PAUSED") }

            it "trusts the live status and moves the question" do
              status_change = stub_status_change("READY")

              described_class.perform_now(question.id, "enable_voting")

              expect(status_change).to have_been_requested
            end
          end

          context "when the live status cannot be read" do
            let(:cached_status) { "READY" }

            before do
              stub_request(:get, "#{api_url}/processes/#{process_id}")
                .to_return(status: 404, body: { error: "not found", code: 40_400 }.to_json, headers: json_headers)
            end

            it "moves the question anyway" do
              status_change = stub_status_change("READY")

              described_class.perform_now(question.id, "enable_voting")

              expect(status_change).to have_been_requested
            end
          end
        end

        describe "a failed close" do
          let(:question_traits) { [:voting_enabled, :published_results] }
          let(:failure) { vocdoni_process.reload.question_failures[question.id.to_s] }

          before { stub_live_status("READY") }

          it "retries a rejected move on the after-end schedule" do
            stub_status_rejected(400)

            expect { described_class.perform_now(question.id, "publish_results") }
              .to have_enqueued_job(described_class)
              .with(question.id, "publish_results", attempt: 2)
              .at(a_value_within(2.seconds).of(SyncElectionResultsJob.poll_delay(1).seconds.from_now))
          end

          it "retries a transient error without raising" do
            stub_status_rejected(503)

            expect { described_class.perform_now(question.id, "publish_results", attempt: 6) }
              .to have_enqueued_job(described_class)
              .with(question.id, "publish_results", attempt: 7)
              .at(a_value_within(2.seconds).of(SyncElectionResultsJob::POLL_CADENCE_S.seconds.from_now))
          end

          it "records the failure for the dashboard without failing the process" do
            stub_status_rejected(400)

            described_class.perform_now(question.id, "publish_results")

            expect(vocdoni_process.reload.state).to eq("published")
            expect(failure).to include("step" => "question_publish_results", "attempts" => 1, "gave_up" => false)
            expect(vocdoni_process.metadata.dig("last_error", "step")).to eq("question_publish_results")
          end

          it "stops retrying after about an hour and says so" do
            stub_status_rejected(400)
            last = described_class::CLOSE_ATTEMPTS

            expect { described_class.perform_now(question.id, "publish_results", attempt: last) }
              .not_to have_enqueued_job(described_class)

            expect(failure).to include("attempts" => last, "gave_up" => true)
          end

          it "spans about an hour of retries" do
            total = (1...described_class::CLOSE_ATTEMPTS).sum { |attempt| described_class.close_delay(attempt) }

            expect(total).to be_within(10.minutes).of(1.hour)
          end

          it "clears the failure once the question is closed" do
            vocdoni_process.record_question_failure!(question.id, "boom", step: "question_publish_results", retries: { attempts: 1 })
            stub_status_change("ENDED")

            described_class.perform_now(question.id, "publish_results", attempt: 2)

            expect(vocdoni_process.reload.question_failures).to be_empty
          end
        end

        context "when the SaaS rejects enable_voting" do
          before { stub_live_status("PAUSED") }

          it "records the error for the question without failing the process or retrying" do
            stub_status_rejected(400)

            expect { described_class.perform_now(question.id, "enable_voting") }
              .not_to have_enqueued_job(described_class)

            vocdoni_process.reload
            expect(vocdoni_process.state).to eq("published")
            expect(vocdoni_process.metadata.dig("last_error", "step")).to eq("question_enable_voting")
            expect(vocdoni_process.question_failures[question.id.to_s]).to include("step" => "question_enable_voting")
          end
        end

        describe "a busy organization" do
          let(:key) { "question_#{question.id}_#{action}" }
          let(:pending) { vocdoni_process.reload.pending_actions[key] }

          def stub_busy
            stub_request(:put, "#{api_url}/processes/#{process_id}/questions/status")
              .to_return(status: 503, body: { error: "another transaction for this organization is in progress", code: 50_303 }.to_json,
                         headers: json_headers)
          end

          def within_jitter(base)
            a_value_between((base * 0.8).seconds.from_now - 1.second, (base * 1.2).seconds.from_now + 1.second)
          end

          context "when closing a question" do
            let(:question_traits) { [:voting_enabled, :published_results] }
            let(:action) { "publish_results" }

            before do
              stub_live_status("READY")
              stub_busy
            end

            it "waits without recording a failure or using a close attempt" do
              expect { described_class.perform_now(question.id, action, attempt: 3) }
                .to have_enqueued_job(described_class)
                .with(question.id, action, attempt: 3, busy_since: kind_of(String), busy_attempts: 1)
                .at(within_jitter(2))

              vocdoni_process.reload
              expect(vocdoni_process).to be_published
              expect(vocdoni_process.question_failures).to be_empty
              expect(vocdoni_process.metadata).not_to have_key("last_error")
              expect(pending).to include("attempts" => 1)
            end

            it "gives up after 15 minutes without a close retry of its own" do
              expect { described_class.perform_now(question.id, action, busy_since: 16.minutes.ago.iso8601, busy_attempts: 60) }
                .not_to have_enqueued_job(described_class)

              expect(pending).to include("gave_up" => true)
              expect(vocdoni_process.question_failures).to be_empty
            end
          end

          context "when enabling voting" do
            let(:action) { "enable_voting" }

            before { stub_live_status("PAUSED") }

            it "waits without raising" do
              stub_busy

              expect { described_class.perform_now(question.id, action) }
                .to have_enqueued_job(described_class)
                .with(question.id, action, attempt: 1, busy_since: kind_of(String), busy_attempts: 1)

              expect(vocdoni_process.reload.question_failures).to be_empty
            end

            it "clears the pending entry once the question opens" do
              vocdoni_process.record_pending_action!(key, since: 1.minute.ago.iso8601, attempts: 2)
              stub_status_change("READY")

              described_class.perform_now(question.id, action, busy_since: 1.minute.ago.iso8601, busy_attempts: 2)

              expect(vocdoni_process.reload.pending_actions).to be_empty
            end
          end

          context "when Decidim moved past the action" do
            let(:question_traits) { [:voting_enabled, :published_results] }
            let(:action) { "enable_voting" }

            it "drops the pending entry with the action" do
              vocdoni_process.record_pending_action!(key, since: 20.minutes.ago.iso8601, attempts: 61, gave_up: true)

              described_class.perform_now(question.id, action)

              expect(vocdoni_process.reload.pending_actions).to be_empty
            end
          end
        end
      end
    end
  end
end
