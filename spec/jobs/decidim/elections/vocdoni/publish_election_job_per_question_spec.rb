# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe PublishElectionJob do
        subject(:job) { described_class.new }

        let(:election) { create(:election, results_availability:) }
        let!(:vocdoni_process) { create(:vocdoni_process, election:) }

        before { job.send(:bootstrap!, election.id) }

        context "with a per_question election" do
          let(:results_availability) { "per_question" }

          it "publishes every question paused" do
            expect(job.send(:process_payload)["initialStatus"]).to eq("PAUSED")
          end

          it "replays the question actions taken before the process reached the chain" do
            idle = create(:election_question, election:)
            open = create(:election_question, :voting_enabled, election:)
            closed = create(:election_question, :voting_enabled, :published_results, election:)

            expect { job.send(:catch_up_questions!) }
              .to have_enqueued_job(UpdateQuestionOnChainJob).with(open.id, "enable_voting")
              .and have_enqueued_job(UpdateQuestionOnChainJob).with(closed.id, "publish_results")
            expect(UpdateQuestionOnChainJob).not_to have_been_enqueued.with(idle.id, anything)
          end
        end

        context "with an after_end election" do
          let(:results_availability) { "after_end" }

          it "publishes every question open" do
            expect(job.send(:process_payload)).not_to have_key("initialStatus")
          end

          it "has no question actions to replay" do
            create(:election_question, :voting_enabled, election:)

            expect { job.send(:catch_up_questions!) }.not_to have_enqueued_job(UpdateQuestionOnChainJob)
          end
        end
      end
    end
  end
end
