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

        context "when the publish failed after the draft reached the SaaS" do
          let!(:vocdoni_process) do
            create(:vocdoni_process, :failed,
                   vocdoni_process_id: process_id,
                   election:)
          end

          before { stub_saas_get(status: nil, published: false) }

          it "keeps the failure and stops polling" do
            expect(described_class).not_to receive(:set)

            described_class.perform_now(election.id)

            expect(vocdoni_process.reload).to be_failed
          end
        end

        context "when a failed publish was completed upstream" do
          let!(:vocdoni_process) do
            create(:vocdoni_process, :failed,
                   vocdoni_process_id: process_id,
                   election:)
          end

          before { stub_saas_get(status: "READY", published: true) }

          it "moves the sidecar to published" do
            described_class.perform_now(election.id)

            expect(vocdoni_process.reload).to be_published
          end
        end

        describe "a rejected read" do
          before do
            stub_request(:get, "#{api_url}/processes/#{process_id}")
              .to_return(status: 404, body: { error: "not found", code: 40_400 }.to_json, headers: json_headers)
          end

          it "records it without failing a published process" do
            described_class.perform_now(election.id)

            vocdoni_process.reload
            expect(vocdoni_process).to be_published
            expect(vocdoni_process.metadata.dig("last_error", "step")).to eq("sync")
          end

          context "when the process is still publishing" do
            let!(:vocdoni_process) { create(:vocdoni_process, :publishing, vocdoni_process_id: process_id, election:) }

            it "fails it as before" do
              described_class.perform_now(election.id)

              expect(vocdoni_process.reload).to be_failed
            end
          end
        end

        describe "reconciling Decidim with the chain" do
          def stub_questions(*statuses)
            stub_request(:get, "#{api_url}/processes/#{process_id}")
              .to_return(status: 200, headers: json_headers,
                         body: { id: process_id, chainId: "vocdoni/LTS/1.2", published: true,
                                 questions: statuses.each_with_index.map { |status, i| { id: "q#{i}", status: } } }.to_json)
          end

          context "when the election ended in Decidim" do
            let(:election) { create(:election, :finished, results_availability:) }

            it "ends the questions still open on chain" do
              stub_questions("ONGOING")

              expect { described_class.perform_now(election.id) }.to have_enqueued_job(EndProcessOnChainJob).with(election.id)
            end

            it "keeps polling while the chain disagrees" do
              stub_questions("PROCESS_UNKNOWN", "ENDED")
              allow(described_class).to receive(:set).and_call_original

              described_class.perform_now(election.id)

              expect(described_class).to have_received(:set).with(wait: described_class::IDLE_CADENCE_S.seconds)
            end

            it "does nothing once every question is closed" do
              stub_questions("ENDED", "RESULTS", "CANCELED")

              expect { described_class.perform_now(election.id) }.not_to have_enqueued_job(EndProcessOnChainJob)
            end

            it "leaves an end that is still waiting on a busy organization alone" do
              vocdoni_process.record_pending_action!("end", since: 1.minute.ago.iso8601, attempts: 4)
              stub_questions("ONGOING")

              expect { described_class.perform_now(election.id) }.not_to have_enqueued_job(EndProcessOnChainJob)
            end

            it "retries an end that gave up" do
              vocdoni_process.record_pending_action!("end", since: 20.minutes.ago.iso8601, attempts: 61, gave_up: true)
              stub_questions("ONGOING")

              expect { described_class.perform_now(election.id) }.to have_enqueued_job(EndProcessOnChainJob).with(election.id)
            end

            it "retries an end whose busy loop went quiet" do
              vocdoni_process.update!(metadata: { "pending_actions" => { "end" => { "since" => 10.minutes.ago.iso8601, "attempts" => 9,
                                                                                    "at" => 3.minutes.ago.iso8601 } } })
              stub_questions("ONGOING")

              expect { described_class.perform_now(election.id) }.to have_enqueued_job(EndProcessOnChainJob).with(election.id)
            end
          end

          context "when the process is not published" do
            let(:election) { create(:election, :finished, results_availability:) }
            let!(:vocdoni_process) { create(:vocdoni_process, :publishing, vocdoni_process_id: process_id, election:) }

            it "enqueues nothing" do
              stub_request(:get, "#{api_url}/processes/#{process_id}")
                .to_return(status: 200, headers: json_headers,
                           body: { id: process_id, chainId: "vocdoni/LTS/1.2", published: false, questions: [{ id: "q0", status: "ONGOING" }] }.to_json)

              expect { described_class.perform_now(election.id) }.not_to have_enqueued_job(EndProcessOnChainJob)
            end
          end

          context "with a per_question election" do
            let(:election) { create(:election, :per_question, :published, :ongoing) }
            let!(:idle) { create(:election_question, election:) }
            let!(:enabled) { create(:election_question, election:, voting_enabled_at: 1.hour.ago) }
            let!(:closed) { create(:election_question, election:, voting_enabled_at: 2.hours.ago, published_results_at: 1.hour.ago) }

            it "enqueues the moves the chain has not made" do
              stub_questions("PAUSED", "PAUSED", "READY")

              expect { described_class.perform_now(election.id) }
                .to have_enqueued_job(UpdateQuestionOnChainJob).with(enabled.id, "enable_voting")
                .and have_enqueued_job(UpdateQuestionOnChainJob).with(closed.id, "publish_results")
              expect(UpdateQuestionOnChainJob).not_to have_been_enqueued.with(idle.id, anything)
              expect(EndProcessOnChainJob).not_to have_been_enqueued
            end

            it "enqueues nothing when the chain agrees" do
              stub_questions("PAUSED", "ONGOING", "ENDED")

              expect { described_class.perform_now(election.id) }.not_to have_enqueued_job(UpdateQuestionOnChainJob)
            end

            it "skips a move that is still waiting on a busy organization" do
              vocdoni_process.record_pending_action!("question_#{closed.id}_publish_results", since: 1.minute.ago.iso8601, attempts: 3)
              stub_questions("PAUSED", "READY", "READY")

              expect { described_class.perform_now(election.id) }.not_to have_enqueued_job(UpdateQuestionOnChainJob)
            end

            it "leaves a question whose own retry loop is running alone" do
              vocdoni_process.record_question_failure!(closed.id, "boom", step: "question_publish_results", retries: { attempts: 2 })
              stub_questions("PAUSED", "READY", "READY")

              expect { described_class.perform_now(election.id) }.not_to have_enqueued_job(UpdateQuestionOnChainJob)
            end

            it "retries a question whose retry loop gave up" do
              vocdoni_process.record_question_failure!(closed.id, "boom", step: "question_publish_results",
                                                                          retries: { attempts: 35, gave_up: true })
              stub_questions("PAUSED", "READY", "READY")

              expect { described_class.perform_now(election.id) }
                .to have_enqueued_job(UpdateQuestionOnChainJob).with(closed.id, "publish_results")
            end

            it "retries an enable_voting whose retries ended" do
              vocdoni_process.update!(metadata: vocdoni_process.metadata.merge(
                "question_failures" => { enabled.id.to_s => { "message" => "boom", "step" => "question_enable_voting",
                                                              "gave_up" => false, "at" => 10.minutes.ago.iso8601 } }
              ))
              stub_questions("PAUSED", "PAUSED", "ONGOING")

              expect { described_class.perform_now(election.id) }
                .to have_enqueued_job(UpdateQuestionOnChainJob).with(enabled.id, "enable_voting")
            end

            it "does not trip on a failure with an unparseable timestamp" do
              vocdoni_process.update!(metadata: vocdoni_process.metadata.merge(
                "question_failures" => { enabled.id.to_s => { "message" => "boom", "gave_up" => false, "at" => "garbage" } }
              ))
              stub_questions("PAUSED", "PAUSED", "ONGOING")

              expect { described_class.perform_now(election.id) }
                .to have_enqueued_job(UpdateQuestionOnChainJob).with(enabled.id, "enable_voting")
            end

            it "gives the admin's own job two minutes first" do
              enabled.update!(voting_enabled_at: 1.minute.ago)
              closed.update!(published_results_at: 1.minute.ago)
              stub_questions("PAUSED", "PAUSED", "READY")

              expect { described_class.perform_now(election.id) }.not_to have_enqueued_job(UpdateQuestionOnChainJob)
            end
          end

          context "when the election ended moments ago" do
            let(:election) { create(:election, results_availability:, start_at: 1.day.ago, end_at: 1.minute.ago) }

            it "gives the admin's own end job two minutes first" do
              stub_questions("ONGOING")

              expect { described_class.perform_now(election.id) }.not_to have_enqueued_job(EndProcessOnChainJob)
            end
          end
        end
      end
    end
  end
end
