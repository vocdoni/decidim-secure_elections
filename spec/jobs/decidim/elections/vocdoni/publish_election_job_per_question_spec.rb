# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe PublishElectionJob do
        subject(:job) { described_class.new }

        let(:election) { create(:election, :with_token_csv_census, results_availability:) }
        let!(:vocdoni_process) { create(:vocdoni_process, election:).tap(&:ensure_attestation_secrets!) }

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

          # The admin enables the question while the process is being pushed:
          # the run has already loaded `election.questions`, and the
          # subscriber's job found no chain election to open.
          it "replays an action taken after the run loaded the questions" do
            question = create(:election_question, :with_response_options, election:)
            job.send(:process_payload)

            Decidim::Elections::Question.find(question.id).update!(voting_enabled_at: Time.current)

            expect { job.send(:catch_up_questions!) }
              .to have_enqueued_job(UpdateQuestionOnChainJob).with(question.id, "enable_voting")
          end
        end

        describe "the multiple-option ballot" do
          let(:results_availability) { "after_end" }

          def type_setup(question)
            job.send(:question_payload, question)["typeSetup"]
          end

          it "caps the selections at max_choices" do
            question = create(:election_question, election:, question_type: "multiple_option", max_choices: 2)
            create_list(:election_response_option, 3, question:)

            expect(type_setup(question)).to include("maxChoices" => 2)
          end

          it "lets a voter pick every option when max_choices is blank, as Decidim does" do
            question = create(:election_question, election:, question_type: "multiple_option", max_choices: nil)
            create_list(:election_response_option, 3, question:)

            expect(type_setup(question)).to include("maxChoices" => 3)
          end

          it "sends no typeSetup for a single-option question" do
            question = create(:election_question, :with_response_options, election:, question_type: "single_option")

            expect(type_setup(question)).to be_nil
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
