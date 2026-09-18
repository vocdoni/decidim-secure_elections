# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    describe SyncResultsJob do
      subject(:job) { described_class.new }

      let(:election) { create(:vocdoni_election, :on_chain) }
      let(:question) { election.questions.first }
      let(:process_id) { election.vocdoni_process_id }

      let(:client) { instance_double(Decidim::Elections::Vocdoni::ApiClient, elections: elections_api) }
      let(:elections_api) { instance_double(Decidim::Elections::Vocdoni::ApiClient::Elections) }

      # The tally as the staging API actually returns it: per-question entries,
      # counts nested one array deep and encoded as strings.
      let(:payload) do
        {
          "id" => process_id,
          "questions" => [
            {
              "questionId" => question.vocdoni_question_id,
              "upstreamId" => question.vocdoni_upstream_id,
              "voteCount" => 2,
              "maxVoters" => 3,
              "finalResults" => false,
              "results" => [%w(1 1)]
            }
          ]
        }
      end

      before do
        allow(Decidim::Elections::Vocdoni::ApiClient).to receive(:new).and_return(client)
        allow(elections_api).to receive(:results).with(process_id).and_return(payload)
      end

      it "fills the local cache" do
        job.perform(election.id)

        election.reload
        expect(election.results_synced_at).to be_present
        expect(election.votes_count).to eq(2)
        expect(election.results_cache.dig("questions", question.id.to_s, "votes_count")).to eq(2)
      end

      it "denormalizes the per-answer counts onto the answers" do
        job.perform(election.id)

        expect(question.answers.reload.map(&:votes_count)).to eq([1, 1])
      end

      it "reads the census size from maxVoters" do
        job.perform(election.id)

        expect(election.reload.census_size).to eq(3)
      end

      it "does nothing for an election that is not on chain" do
        off_chain = create(:vocdoni_election)

        expect(elections_api).not_to receive(:results)

        job.perform(off_chain.id)
      end

      context "when the tally is not available yet" do
        let(:payload) { { "id" => process_id, "questions" => [{ "questionId" => question.vocdoni_question_id }] } }

        it "stores zeroes instead of raising" do
          expect { job.perform(election.id) }.not_to raise_error

          expect(election.reload.votes_count).to eq(0)
          expect(question.answers.reload.map(&:votes_count)).to eq([0, 0])
        end
      end

      context "when several questions are tallied" do
        let(:election) { create(:vocdoni_election, :on_chain, questions_count: 2) }

        let(:payload) do
          {
            "id" => process_id,
            "questions" => election.questions.map.with_index do |q, index|
              {
                "questionId" => q.vocdoni_question_id,
                "upstreamId" => q.vocdoni_upstream_id,
                "voteCount" => index.zero? ? 5 : 3,
                "results" => [[index.zero? ? "5" : "3", "0"]]
              }
            end
          }
        end

        # Every question is its own Vochain election, so a voter contributes one
        # vote per question; summing them would report a wildly inflated turnout.
        it "reports the busiest question rather than the sum" do
          job.perform(election.id)

          expect(election.reload.votes_count).to eq(5)
        end
      end

      context "when the API fails" do
        before do
          allow(elections_api).to receive(:results).and_raise(
            Decidim::Elections::Vocdoni::ApiError.new("boom", status: 502)
          )
        end

        it "records the failure and re-raises" do
          expect { job.perform(election.id) }.to raise_error(Decidim::Elections::Vocdoni::ApiError)

          expect(election.reload.last_error_message).to include("boom")
        end
      end
    end
  end
end
end
