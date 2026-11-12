# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe LiveResultsSync do
        let(:results_availability) { "real_time" }
        let(:election) { create(:election, results_availability:) }
        let!(:process) { create(:vocdoni_process, :published, election:) }

        describe ".applies_to?" do
          it "is true for a published real_time election" do
            expect(described_class.applies_to?(election)).to be(true)
          end

          context "when results are only shown after the end" do
            let(:results_availability) { "after_end" }

            it { expect(described_class.applies_to?(election)).to be(false) }
          end

          context "when the process is not on chain yet" do
            let!(:process) { create(:vocdoni_process, :publishing, election:) }

            it { expect(described_class.applies_to?(election)).to be(false) }
          end
        end

        describe ".request!" do
          it "starts one chain and coalesces the notifications that follow" do
            expect do
              expect(described_class.request!(process)).to be(true)
              4.times { expect(described_class.request!(process)).to be(false) }
            end.to have_enqueued_job(SyncResultsAfterVoteJob).exactly(:once).with(election.id, seen: 1)

            process.reload
            expect(process.live_sync_requests).to eq(5)
            expect(process.live_sync_until).to be > Time.current
          end

          it "starts a new chain once the lease has lapsed" do
            process.update!(live_sync_until: 1.second.ago)

            expect { described_class.request!(process) }
              .to have_enqueued_job(SyncResultsAfterVoteJob).with(election.id, seen: 1)
          end
        end

        describe ".release!" do
          before { process.update!(live_sync_requests: 3, live_sync_until: 1.minute.from_now) }

          it "drops the lease when no notification arrived after the given count" do
            expect(described_class.release!(process, requests: 3)).to be(true)
            expect(process.reload.live_sync_until).to be_nil
          end

          it "keeps the lease when a notification arrived meanwhile" do
            expect(described_class.release!(process, requests: 2)).to be(false)
            expect(process.reload.live_sync_until).to be_present
          end
        end

        describe ".hold!" do
          it "extends the lease past the next check" do
            described_class.hold!(process, 30)

            expect(process.reload.live_sync_until).to be > (30 + described_class::LEASE_GRACE_S - 5).seconds.from_now
          end
        end
      end
    end
  end
end
