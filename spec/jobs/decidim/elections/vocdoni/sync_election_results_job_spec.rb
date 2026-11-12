# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe SyncElectionResultsJob do
        let(:api_url) { "https://saas-api.example.org" }
        let(:process_id) { "6885f0c2c1a4e2f0b1d33a01" }
        let(:json_headers) { { "Content-Type" => "application/json" } }
        let(:election) { create(:election) }
        let!(:question) do
          create(:election_question, :with_response_options, election:)
        end
        let!(:vocdoni_process) do
          create(:vocdoni_process, :published,
                 vocdoni_process_id: process_id,
                 election:)
        end

        def vocdoni_fixture(name)
          Decidim::Elections::Vocdoni::Engine.root.join("spec", "fixtures", "vocdoni", "#{name}.json").read
        end

        # The shipped fixture reports `finalResults: false`, so a run against
        # it must apply what is there AND reschedule itself for another
        # attempt.
        it "mirrors the tally and reschedules while any question is still not final" do
          stub_request(:get, "#{api_url}/processes/#{process_id}/results")
            .to_return(status: 200, body: vocdoni_fixture("process_results"), headers: json_headers)

          expect(described_class).to receive(:set).with(wait: 5.seconds).and_call_original
          expect_any_instance_of(ActiveJob::ConfiguredJob).to receive(:perform_later).with(election.id, attempt: 2) # rubocop:disable RSpec/AnyInstance

          described_class.perform_now(election.id)

          counts = question.response_options.order(:id).pluck(:votes_count)
          expect(counts).to eq([1, 1])
        end

        it "backs off on later attempts" do
          stub_request(:get, "#{api_url}/processes/#{process_id}/results")
            .to_return(status: 200, body: vocdoni_fixture("process_results"), headers: json_headers)

          expect(described_class).to receive(:set).with(wait: 30.seconds).and_call_original
          expect_any_instance_of(ActiveJob::ConfiguredJob).to receive(:perform_later).with(election.id, attempt: 5) # rubocop:disable RSpec/AnyInstance

          described_class.perform_now(election.id, attempt: 4)
        end

        describe ".poll_delay" do
          it "waits 5, 10, 15, 30, 60 s and then every 120 s" do
            delays = (1..8).map { |attempt| described_class.poll_delay(attempt) }

            expect(delays).to eq([5, 10, 15, 30, 60, 120, 120, 120])
          end

          it "gives up after about an hour" do
            window = (1...described_class::MAX_POLL_ATTEMPTS).sum { |attempt| described_class.poll_delay(attempt) }

            expect(window).to eq(60.minutes.to_i)
          end
        end

        it "stops rescheduling once every question is final" do
          final = JSON.parse(vocdoni_fixture("process_results"))
          final["questions"].each { |q| q["finalResults"] = true }

          stub_request(:get, "#{api_url}/processes/#{process_id}/results")
            .to_return(status: 200, body: final.to_json, headers: json_headers)

          expect(described_class).not_to receive(:set)

          described_class.perform_now(election.id)

          counts = question.response_options.order(:id).pluck(:votes_count)
          expect(counts).to eq([1, 1])
        end

        it "stops rescheduling when the retry budget is exhausted" do
          stub_request(:get, "#{api_url}/processes/#{process_id}/results")
            .to_return(status: 200, body: vocdoni_fixture("process_results"), headers: json_headers)

          expect(described_class).not_to receive(:set)

          described_class.perform_now(election.id, attempt: described_class::MAX_POLL_ATTEMPTS)
        end

        it "applies the tally without rescheduling in :one_shot mode" do
          stub_request(:get, "#{api_url}/processes/#{process_id}/results")
            .to_return(status: 200, body: vocdoni_fixture("process_results"), headers: json_headers)

          expect(described_class).not_to receive(:set)

          described_class.perform_now(election.id, mode: :one_shot)

          counts = question.response_options.order(:id).pluck(:votes_count)
          expect(counts).to eq([1, 1])
        end

        context "when limited to some questions" do
          let!(:other) { create(:election_question, :with_response_options, election:) }
          let!(:vocdoni_process) do
            create(:vocdoni_process, :published,
                   vocdoni_process_id: process_id, election:,
                   metadata: { "questions" => [
                     { "decidim_question_id" => question.id, "vocdoni_question_id" => "remote-a" },
                     { "decidim_question_id" => other.id, "vocdoni_question_id" => "remote-b" }
                   ] })
          end

          before do
            # Listed in the opposite order to the local questions, to prove
            # the match is by id and not by position.
            stub_request(:get, "#{api_url}/processes/#{process_id}/results")
              .to_return(status: 200, headers: json_headers, body: {
                "questions" => [
                  { "questionId" => "remote-b", "finalResults" => false, "results" => [%w(7 8)] },
                  { "questionId" => "remote-a", "finalResults" => true, "results" => [%w(3 4)] }
                ]
              }.to_json)
          end

          it "writes and polls only those questions" do
            expect(described_class).not_to receive(:set)

            described_class.perform_now(election.id, question_ids: [question.id])

            expect(question.response_options.order(:id).pluck(:votes_count)).to eq([3, 4])
            expect(other.response_options.order(:id).pluck(:votes_count)).to eq([0, 0])
          end

          it "keeps the scope when it reschedules" do
            expect(described_class).to receive(:set).with(wait: described_class.poll_delay(1).seconds).and_call_original
            expect_any_instance_of(ActiveJob::ConfiguredJob).to receive(:perform_later).with(election.id, attempt: 2, question_ids: [other.id]) # rubocop:disable RSpec/AnyInstance

            described_class.perform_now(election.id, question_ids: [other.id])

            expect(other.response_options.order(:id).pluck(:votes_count)).to eq([7, 8])
          end
        end

        it "rejects an unknown mode" do
          expect { described_class.perform_now(election.id, mode: :bogus) }
            .to raise_error(ArgumentError, /Unknown mode/)
        end

        context "when the sidecar is not on chain yet" do
          let!(:vocdoni_process) do
            create(:vocdoni_process, :publishing,
                   vocdoni_process_id: process_id,
                   election:)
          end

          it "does not read /results and does not touch counters" do
            described_class.perform_now(election.id)

            counts = question.response_options.order(:id).pluck(:votes_count)
            expect(counts).to eq([0, 0])
          end
        end
      end
    end
  end
end
