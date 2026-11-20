# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe PublishElectionJob do
        let(:election) { create(:election) }
        let(:state) { "pending" }
        let!(:vocdoni_process) { create(:vocdoni_process, election:, state:) }
        let(:busy) { ApiError.new("another transaction for this organization is in progress", status: 503, code: 50_303) }
        let(:pending) { vocdoni_process.reload.pending_actions["publish"] }

        # Runs the job with its steps stubbed: the census step answers `error`,
        # or every step succeeds when `error` is nil.
        def run(*, error: busy, **)
          job = described_class.new(election.id, *, **)
          if error
            allow(job).to receive(:prepare_census!).and_raise(error)
          else
            allow(job).to receive_messages(prepare_census!: nil, ensure_process_created!: nil,
                                           ensure_process_published!: nil, persist_process_metadata!: nil)
          end
          job.perform_now
          job
        end

        def within_jitter(base)
          a_value_between((base * 0.8).seconds.from_now - 1.second, (base * 1.2).seconds.from_now + 1.second)
        end

        it "waits for the organization while the process stays publishing" do
          expect { run }
            .to have_enqueued_job(described_class)
            .with(election.id, nil, busy: { "since" => kind_of(String), "attempts" => 1 })
            .at(within_jitter(2))

          vocdoni_process.reload
          expect(vocdoni_process).to be_publishing
          expect(vocdoni_process.last_error).to be_nil
          expect(vocdoni_process.metadata).not_to have_key("last_error")
          expect(pending).to include("attempts" => 1)
        end

        it "never waits less than Retry-After" do
          error = ApiError.new("busy", status: 503, code: 50_303, retry_after: 40)

          expect { run(error:) }.to have_enqueued_job(described_class).at(within_jitter(40))
        end

        context "when a busy wait comes back to a publishing process" do
          let(:state) { "publishing" }

          it "carries on with the push" do
            since = 1.minute.ago.iso8601
            job = nil

            expect { job = run(nil, busy: { "since" => since, "attempts" => 3 }) }
              .to have_enqueued_job(described_class)
              .with(election.id, nil, busy: { "since" => since, "attempts" => 4 })
              .at(within_jitter(15))
            expect(job).to have_received(:prepare_census!)
          end

          it "still skips a fresh run, which would push twice" do
            job = run

            expect(job).not_to have_received(:prepare_census!)
          end

          it "fails the process once the window runs out" do
            expect { run(nil, busy: { "since" => 16.minutes.ago.iso8601, "attempts" => 60 }) }
              .not_to have_enqueued_job(described_class)

            expect(pending).to include("attempts" => 61, "gave_up" => true)
            expect(vocdoni_process).to be_failed
            expect(vocdoni_process.last_error).to include("another transaction")
          end
        end

        context "when the Retry button runs a given-up publish again" do
          let(:state) { "failed" }

          it "opens a new window" do
            vocdoni_process.record_pending_action!("publish", since: 30.minutes.ago.iso8601, attempts: 61, gave_up: true)

            expect { run }
              .to have_enqueued_job(described_class)
              .with(election.id, nil, busy: { "since" => kind_of(String), "attempts" => 1 })

            expect(pending).to include("attempts" => 1)
            expect(pending).not_to have_key("gave_up")
          end
        end

        it "clears the pending entry once the process is published" do
          vocdoni_process.record_pending_action!("publish", since: 1.minute.ago.iso8601, attempts: 2)

          run(error: nil)

          expect(vocdoni_process.reload).to be_published
          expect(vocdoni_process.pending_actions).to be_empty
        end

        it "fails as before on any other error" do
          vocdoni_process.record_pending_action!("publish", since: 1.minute.ago.iso8601, attempts: 2)

          run(error: ApiError.new("invalid census", status: 400, code: 40_004))

          vocdoni_process.reload
          expect(vocdoni_process).to be_failed
          expect(vocdoni_process.pending_actions).to be_empty
        end
      end
    end
  end
end
