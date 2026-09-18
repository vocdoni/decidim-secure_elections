# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    describe Question do
      subject(:question) { create(:vocdoni_question, :with_answers) }

      it { is_expected.to be_valid }

      describe "#complete?" do
        it "needs at least two answers" do
          question.answers.last.destroy!
          question.reload

          expect(question).not_to be_complete
        end

        it "is complete with two answers" do
          expect(question).to be_complete
        end

        context "with a multiple choice question" do
          subject(:question) { create(:vocdoni_question, :multichoice, :with_answers, answers_count: 3) }

          it "is complete with coherent bounds" do
            expect(question).to be_complete
          end

          it "is incomplete when the maximum exceeds the number of answers" do
            # Written past the validations on purpose: the point is to prove
            # `complete?` catches bounds that a form would never have let
            # through, so the row has to be put into a state the form forbids.
            question.update_columns(max_choices: 9) # rubocop:disable Rails/SkipsModelValidations
            question.reload

            expect(question).not_to be_complete
          end
        end
      end

      describe "#resequence_answers!" do
        subject(:question) { create(:vocdoni_question, :with_answers, answers_count: 3) }

        it "keeps the choice values contiguous and 0-based after a deletion" do
          question.answers.find_by(value: 1).destroy!
          question.resequence_answers!

          expect(question.answers.reload.map(&:value)).to eq([0, 1])
          expect(question.answers.map(&:position)).to eq([0, 1])
        end
      end

      describe "#votes_count and #results" do
        let(:election) { question.election }

        before do
          election.update!(
            results_cache: {
              "questions" => {
                question.id.to_s => { "votes_count" => 7, "answers" => {} }
              }
            }
          )
        end

        it "reads the cached tally instead of the API" do
          expect(question.votes_count).to eq(7)
        end
      end

      describe ".normalize_status" do
        it "accepts the API vocabulary, including ONGOING" do
          expect(described_class.normalize_status("ONGOING")).to eq("ongoing")
          expect(described_class.normalize_status("Ready")).to eq("ready")
        end

        it "returns nil for anything else" do
          expect(described_class.normalize_status("NOPE")).to be_nil
        end
      end

      describe "validations" do
        it "rejects a camelCase question type" do
          question.question_type = "singleChoice"

          expect(question).not_to be_valid
        end

        it "rejects a maximum below the minimum" do
          question.question_type = "multichoice"
          question.min_choices = 3
          question.max_choices = 2

          expect(question).not_to be_valid
        end
      end
    end
  end
end
end
