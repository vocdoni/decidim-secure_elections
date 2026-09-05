# frozen_string_literal: true

require "spec_helper"

module Decidim
  module SecureElections
    module Admin
      # Step 2 of the wizard. The whole ballot arrives in one submit — questions
      # and their options together — and this is a reconciliation, not a series
      # of edits: what the form carries is what the election ends up with.
      describe UpdateElectionQuestions do
        subject(:command) { described_class.new(form, election) }

        let(:organization) { create(:organization, available_locales: [:en]) }
        let(:participatory_space) { create(:participatory_process, organization:) }
        let(:component) { create(:vocdoni_component, participatory_space:) }
        let(:user) { create(:user, :admin, :confirmed, organization:) }
        let(:election) { create(:vocdoni_election, :with_questions, component:, questions_count: 1, answers_count: 2) }

        let(:question) { election.questions.first }
        let(:options) { question.answers.to_a }

        let(:context) do
          { current_organization: organization, current_component: component, current_user: user, election: }
        end

        let(:question_attributes) do
          {
            "0" => {
              id: question.id,
              uid: "q0",
              question_type: "singlechoice",
              title_en: "Do you agree?",
              description_en: "",
              answers: {
                "0" => { id: options.first.id, uid: "q0-a0", title_en: "Yes" },
                "1" => { id: options.second.id, uid: "q0-a1", title_en: "No" }
              }
            }
          }
        end

        let(:attributes) do
          {
            election: {
              questions: question_attributes
            }
          }
        end

        let(:form) { ElectionQuestionsForm.from_params(attributes).with_context(context) }

        it "broadcasts ok" do
          expect { command.call }.to broadcast(:ok)
        end

        it "saves the questions and their options in one go" do
          command.call
          election.reload

          expect(election.questions.size).to eq(1)
          expect(election.questions.first.answers.map { |answer| translated(answer.title) }).to eq(%w(Yes No))
        end

        it "keeps the identity of the records that were already there" do
          command.call

          expect(election.questions.reload.first.id).to eq(question.id)
        end

        it "hands the ids back so a repeated autosave is idempotent" do
          command.call

          expect(form.saved_ids["q0"]["id"]).to eq(question.id)
          expect(form.saved_ids["q0"]["answers"]["q0-a0"]).to eq(options.first.id)
        end

        context "when a question is added" do
          before do
            question_attributes["1"] = {
              uid: "q1",
              question_type: "singlechoice",
              title_en: "And this one?",
              description_en: "",
              answers: {
                "0" => { uid: "q1-a0", title_en: "Sure" },
                "1" => { uid: "q1-a1", title_en: "Never" }
              }
            }
          end

          it "creates it with the right position" do
            command.call

            expect(election.questions.reload.map(&:position)).to eq([0, 1])
          end

          it "reports the id it was given" do
            command.call

            expect(form.saved_ids["q1"]["id"]).to be_present
          end
        end

        context "when a question is removed" do
          let(:election) { create(:vocdoni_election, :with_questions, component:, questions_count: 2, answers_count: 2) }
          let(:question) { election.questions.first }

          it "destroys the ones that did not come back" do
            expect { command.call }.to change { election.questions.reload.size }.from(2).to(1)
          end
        end

        context "when an option is added" do
          before do
            question_attributes["0"][:answers]["2"] = { uid: "q0-a2", title_en: "Abstain" }
          end

          it "gives it the next contiguous on-chain value" do
            command.call

            expect(question.answers.reload.map(&:value)).to eq([0, 1, 2])
          end
        end

        context "when an option is removed" do
          before do
            question_attributes["0"][:answers] = {
              "0" => { id: options.second.id, uid: "q0-a1", title_en: "No" },
              "1" => { uid: "q0-a2", title_en: "Abstain" }
            }
          end

          it "renumbers the survivors so the ballot encoding stays 0-based" do
            command.call
            values = question.answers.reload

            expect(values.map(&:value)).to eq([0, 1])
            expect(values.map { |answer| translated(answer.title) }).to eq(%w(No Abstain))
          end
        end

        context "when the options are reordered" do
          before do
            question_attributes["0"][:answers] = {
              "0" => { id: options.second.id, uid: "q0-a1", title_en: "No" },
              "1" => { id: options.first.id, uid: "q0-a0", title_en: "Yes" }
            }
          end

          # A plain swap would trip the (question, value) unique index halfway
          # through, which is why the command parks the old values first.
          it "swaps their on-chain values without colliding" do
            expect { command.call }.to broadcast(:ok)

            expect(question.answers.reload.map { |answer| [answer.id, answer.value] })
              .to eq([[options.second.id, 0], [options.first.id, 1]])
          end
        end

        context "when the election hides results until the end" do
          # secret_until_the_end is now derived from election.results_availability,
          # not from a form attribute. The Main tab owns results_availability;
          # the Questions command reads it from the election record.
          let(:election) do
            create(:vocdoni_election, :with_questions, component:,
                                                       questions_count: 1, answers_count: 2,
                                                       results_availability: "after_end")
          end

          it "marks every question secret_until_the_end" do
            command.call

            expect(election.questions.reload.map(&:secret_until_the_end)).to all(be(true))
          end
        end

        context "when the per-question type is multichoice" do
          # question_type is now per-question; each card's select is submitted
          # with the question params rather than at the election level.
          before do
            question_attributes["0"][:question_type] = "multichoice"
            question_attributes["0"][:min_choices] = 1
            question_attributes["0"][:max_choices] = 2
          end

          it "saves the multichoice type and the choice bounds" do
            command.call

            expect(election.questions.first.reload.question_type).to eq("multichoice")
            expect(election.questions.first.max_choices).to eq(2)
          end
        end

        context "when an id from another election is submitted" do
          let(:other_question) { create(:vocdoni_question, :with_answers) }

          before { question_attributes["0"][:id] = other_question.id }

          it "ignores it and creates a new question instead of stealing one" do
            command.call

            expect(election.questions.reload.map(&:id)).not_to include(other_question.id)
            expect(other_question.reload.election).not_to eq(election)
          end
        end

        context "when a question has only one option" do
          before do
            question_attributes["0"][:answers] = { "0" => { id: options.first.id, uid: "q0-a0", title_en: "Yes" } }
          end

          it "refuses: one option is not a choice" do
            expect { command.call }.to broadcast(:invalid)
            expect(question.answers.reload.size).to eq(2)
          end
        end

        context "when the election is already on chain" do
          let(:election) { create(:vocdoni_election, :on_chain, :with_questions, component:, questions_count: 1, answers_count: 2) }

          it "refuses: each question is its own Vochain election by then" do
            expect { command.call }.to broadcast(:invalid)
          end
        end
      end
    end
  end
end
