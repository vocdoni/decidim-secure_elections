# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe Process do
        let(:process) { create(:vocdoni_process, :published) }

        describe "#record_pending_action!" do
          it "writes the entry under its key" do
            process.record_pending_action!("end", since: "2026-11-20T10:00:00Z", attempts: 2)

            entry = process.reload.pending_actions["end"]
            expect(entry).to include("since" => "2026-11-20T10:00:00Z", "attempts" => 2)
            expect(entry["at"]).to be_present
            expect(entry).not_to have_key("gave_up")
          end

          it "keeps the entries another job wrote meanwhile" do
            Process.find(process.id).record_pending_action!("publish", since: "2026-11-20T10:00:00Z", attempts: 1)

            process.record_pending_action!("end", since: "2026-11-20T10:00:00Z", attempts: 1, gave_up: true)

            expect(process.reload.pending_actions.keys).to contain_exactly("publish", "end")
            expect(process.pending_actions["end"]["gave_up"]).to be(true)
          end

          it "leaves the state and last_error alone" do
            process.record_pending_action!("end", since: "2026-11-20T10:00:00Z", attempts: 1)

            expect(process.reload).to be_published
            expect(process.last_error).to be_nil
          end
        end

        describe "#clear_pending_action!" do
          it "removes only that entry" do
            process.record_pending_action!("end", since: "2026-11-20T10:00:00Z", attempts: 1)
            process.record_pending_action!("question_1_enable_voting", since: "2026-11-20T10:00:00Z", attempts: 1)

            Process.find(process.id).clear_pending_action!("end")

            expect(process.reload.pending_actions.keys).to eq(["question_1_enable_voting"])
          end
        end

        describe "#pending_action_live?" do
          it "is live while the job keeps rescheduling" do
            process.record_pending_action!("end", since: 1.minute.ago.iso8601, attempts: 3)

            expect(process.pending_action_live?("end")).to be(true)
          end

          it "is not live once given up" do
            process.record_pending_action!("end", since: 20.minutes.ago.iso8601, attempts: 60, gave_up: true)

            expect(process.pending_action_live?("end")).to be(false)
          end

          it "is not live when the last busy answer is older than two minutes" do
            process.update!(metadata: { "pending_actions" => { "end" => { "since" => 10.minutes.ago.iso8601, "attempts" => 4,
                                                                          "at" => 3.minutes.ago.iso8601 } } })

            expect(process.pending_action_live?("end")).to be(false)
          end

          it "is not live without an entry" do
            expect(process.pending_action_live?("end")).to be(false)
          end
        end
      end

      describe BusyRetry do
        describe ".busy_delay" do
          let(:job_class) { Class.new { include BusyRetry } }

          it "backs off 2, 4 and 8 s, then every 15 s, with ±20 % jitter" do
            [[1, 2], [2, 4], [3, 8], [4, 15], [40, 15]].each do |attempt, base|
              20.times { expect(job_class.busy_delay(attempt)).to be_between(base * 0.8, base * 1.2) }
            end
          end

          it "never waits less than Retry-After" do
            expect(job_class.busy_delay(1, retry_after: 30)).to eq(30)
          end

          it "never waits less than a second" do
            allow(job_class).to receive(:rand).and_return(0.0)

            expect(job_class.busy_delay(1)).to eq(1)
          end
        end
      end
    end
  end
end
