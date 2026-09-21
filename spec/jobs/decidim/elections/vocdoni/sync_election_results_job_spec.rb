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

          expect(described_class).to receive(:set).with(wait: described_class::POLL_CADENCE_S.seconds).and_call_original
          expect_any_instance_of(ActiveJob::ConfiguredJob).to receive(:perform_later).with(election.id, attempt: 2) # rubocop:disable RSpec/AnyInstance

          described_class.perform_now(election.id)

          counts = question.response_options.order(:id).pluck(:votes_count)
          expect(counts).to eq([1, 1])
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
