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
          create(:election_question, :with_response_options, election:, question_type: "single_option")
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
          let!(:other) { create(:election_question, :with_response_options, election:, question_type: "single_option") }
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

        describe "result matrices" do
          let(:election) { create(:election, results_availability: "after_end") }
          let!(:question) do
            create(:election_question, election:, question_type: "single_option").tap do |q|
              create_list(:election_response_option, 3, question: q)
            end
          end
          let!(:multi) do
            create(:election_question, election:, question_type: "multiple_option", max_choices: 2).tap do |q|
              create_list(:election_response_option, 3, question: q)
            end
          end
          let!(:approval) do
            create(:election_question, election:, question_type: "multiple_option", max_choices: nil).tap do |q|
              create_list(:election_response_option, 2, question: q)
            end
          end
          let!(:vocdoni_process) do
            create(:vocdoni_process, :published,
                   vocdoni_process_id: process_id, election:,
                   metadata: { "questions" => [
                     { "decidim_question_id" => question.id, "vocdoni_question_id" => "q-single" },
                     { "decidim_question_id" => multi.id, "vocdoni_question_id" => "q-multi" },
                     { "decidim_question_id" => approval.id, "vocdoni_question_id" => "q-approval" }
                   ] })
          end

          # As the SaaS relays the Vochain tally: a singlechoice question is
          # one field (one row, a bucket per choice); a multichoice question
          # is a 0/1 field per choice (a row per choice: [not selected, selected]).
          let(:remote_questions) do
            [
              { "questionId" => "q-single", "voteCount" => 6, "finalResults" => true, "results" => [%w(3 1 2)] },
              # 5 ballots picking up to 2 of 3: A on 4, B on 1, C on 3.
              { "questionId" => "q-multi", "voteCount" => 5, "finalResults" => true,
                "results" => [%w(1 4), %w(4 1), %w(2 3)] },
              # The dev E2E tally (election #54): one ballot for the first option.
              { "questionId" => "q-approval", "voteCount" => 1, "finalResults" => true,
                "results" => [%w(0 1), %w(1 0)] }
            ]
          end

          before do
            # Read at request time, so an example can edit the tally first.
            stub_request(:get, "#{api_url}/processes/#{process_id}/results")
              .to_return { { status: 200, headers: json_headers, body: { "questions" => remote_questions }.to_json } }
          end

          def counts(local)
            local.response_options.order(:id).pluck(:votes_count)
          end

          it "writes the count of every option of every question" do
            described_class.perform_now(election.id)

            expect(counts(question)).to eq([3, 1, 2])
            expect(counts(multi)).to eq([4, 1, 3])
            expect(counts(approval)).to eq([1, 0])
            expect(election.reload.votes_count).to eq(12)
          end

          it "writes one multiple-option question of a per-question election" do
            described_class.perform_now(election.id, question_ids: [multi.id])

            expect(counts(multi)).to eq([4, 1, 3])
            expect(counts(question)).to eq([0, 0, 0])
            expect(counts(approval)).to eq([0, 0])
          end

          it "leaves a question with no tally yet alone" do
            remote_questions[1] = remote_questions[1].merge("results" => nil, "finalResults" => false)

            described_class.perform_now(election.id, mode: :one_shot)

            expect(counts(multi)).to eq([0, 0, 0])
            expect(vocdoni_process.reload.question_failures).to be_empty
          end

          context "when a matrix does not have the shape of its question" do
            # A single-row matrix for a three-option multiple-option question.
            before { remote_questions[1] = remote_questions[1].merge("results" => [%w(4 1 3)]) }

            it "writes no counts for it and raises a dashboard alert" do
              described_class.perform_now(election.id)

              expect(counts(multi)).to eq([0, 0, 0])
              expect(counts(question)).to eq([3, 1, 2])
              failure = vocdoni_process.reload.question_failures[multi.id.to_s]
              expect(failure).to include("step" => "sync_results")
              expect(failure["message"]).to include("multiple_option question with 3 options")
              expect(vocdoni_process).to be_published
            end

            it "clears the alert once a run maps the tally" do
              described_class.perform_now(election.id, mode: :one_shot)
              remote_questions[1] = remote_questions[1].merge("results" => [%w(1 4), %w(4 1), %w(2 3)])

              described_class.perform_now(election.id, mode: :one_shot)

              expect(counts(multi)).to eq([4, 1, 3])
              expect(vocdoni_process.reload.question_failures).to be_empty
            end
          end

          it "rejects a single-option row that does not have a bucket per option" do
            remote_questions[0] = remote_questions[0].merge("results" => [%w(3 1)])

            described_class.perform_now(election.id, mode: :one_shot)

            expect(counts(question)).to eq([0, 0, 0])
            expect(vocdoni_process.reload.question_failures[question.id.to_s]).to include("step" => "sync_results")
          end

          it "rejects a count that is not a number" do
            remote_questions[2] = remote_questions[2].merge("results" => [%w(0 x), %w(1 0)])

            described_class.perform_now(election.id, mode: :one_shot)

            expect(counts(approval)).to eq([0, 0])
            expect(vocdoni_process.reload.question_failures).to have_key(approval.id.to_s)
          end

          it "keeps a chain status failure of the same question" do
            vocdoni_process.record_question_failure!(multi.id, "boom", step: "question_publish_results")

            described_class.perform_now(election.id, mode: :one_shot)

            expect(vocdoni_process.reload.question_failures[multi.id.to_s]).to include("step" => "question_publish_results")
          end
        end

        it "rejects an unknown mode" do
          expect { described_class.perform_now(election.id, mode: :bogus) }
            .to raise_error(ArgumentError, /Unknown mode/)
        end

        it "writes the remote voteCount into the question's votes_count" do
          stub_request(:get, "#{api_url}/processes/#{process_id}/results")
            .to_return(status: 200, body: vocdoni_fixture("process_results"), headers: json_headers)

          described_class.perform_now(election.id, mode: :one_shot)

          question.reload
          expect(question.votes_count).to eq(2) # fixture voteCount: 2
        end

        it "keeps election.votes_count equal to the sum of its questions' votes_count" do
          stub_request(:get, "#{api_url}/processes/#{process_id}/results")
            .to_return(status: 200, body: vocdoni_fixture("process_results"), headers: json_headers)

          described_class.perform_now(election.id, mode: :one_shot)

          election.reload
          expect(election.votes_count).to eq(election.questions.sum(:votes_count))
          expect(election.votes_count).to eq(2)
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

        # A results read that fails after publish must not mark the process failed (#84).
        it "records a failed read without failing the process" do
          stub_request(:get, "#{api_url}/processes/#{process_id}/results")
            .to_return(status: 404, body: { error: "not found", code: 40_400 }.to_json, headers: json_headers)

          described_class.perform_now(election.id)

          vocdoni_process.reload
          expect(vocdoni_process).to be_published
          expect(vocdoni_process.metadata.dig("last_error", "step")).to eq("sync_results")
        end
      end
    end
  end
end
