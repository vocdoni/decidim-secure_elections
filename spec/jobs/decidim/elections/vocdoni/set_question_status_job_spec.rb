# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    describe SetQuestionStatusJob do
      subject(:job) { described_class.new }

      let(:election) { create(:vocdoni_election, :on_chain, questions_count: 2) }
      let(:process_id) { election.vocdoni_process_id }

      let(:client) { instance_double(Decidim::Elections::Vocdoni::ApiClient, elections: elections_api, jobs: jobs_api) }
      let(:elections_api) { instance_double(Decidim::Elections::Vocdoni::ApiClient::Elections) }
      let(:jobs_api) { instance_double(Decidim::Elections::Vocdoni::ApiClient::Jobs) }

      before do
        allow(Decidim::Elections::Vocdoni::ApiClient).to receive(:new).and_return(client)
        allow(elections_api).to receive(:bulk_set_question_status).and_return({ "jobId" => "job-9" })
        allow(jobs_api).to receive(:wait_for).and_return({ "status" => "completed" })
      end

      it "sends the status in the API's uppercase vocabulary" do
        job.perform(election.id, "paused")

        expect(elections_api).to have_received(:bulk_set_question_status)
          .with(process_id, status: "PAUSED", question_ids: nil)
      end

      it "omits the question ids when the whole process is moved" do
        job.perform(election.id, "ended")

        expect(elections_api).to have_received(:bulk_set_question_status)
          .with(process_id, status: "ENDED", question_ids: nil)
      end

      it "stores the new status locally, in lowercase" do
        job.perform(election.id, "paused")

        expect(election.reload.status).to eq("paused")
        expect(election.questions.map(&:vocdoni_status).uniq).to eq(["paused"])
      end

      it "asks for a fresh tally afterwards" do
        expect { job.perform(election.id, "ended") }
          .to have_enqueued_job(Decidim::Elections::Vocdoni::SyncResultsJob).with(election.id)
      end

      context "when only some questions are moved" do
        let(:target) { election.questions.first }

        it "sends their upstream ids" do
          job.perform(election.id, "paused", [target.id])

          expect(elections_api).to have_received(:bulk_set_question_status)
            .with(process_id, status: "PAUSED", question_ids: [target.vocdoni_question_id])
        end

        it "leaves the election status alone" do
          job.perform(election.id, "paused", [target.id])

          expect(election.reload.status).to eq("ready")
          expect(target.reload.vocdoni_status).to eq("paused")
        end
      end

      it "ignores an unknown status" do
        expect(elections_api).not_to receive(:bulk_set_question_status)

        job.perform(election.id, "explode")
      end

      it "does nothing for an election that is not on chain" do
        off_chain = create(:vocdoni_election)

        expect(elections_api).not_to receive(:bulk_set_question_status)

        job.perform(off_chain.id, "paused")
      end
    end
  end
end
end
