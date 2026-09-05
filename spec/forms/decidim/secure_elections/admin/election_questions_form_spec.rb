# frozen_string_literal: true

require "spec_helper"

module Decidim
  module SecureElections
    module Admin
      # Step 2 of the wizard: the ballot. Questions and their options arrive
      # together, in one submit, so that adding an option costs no page load.
      describe ElectionQuestionsForm do
        subject(:form) { described_class.from_params(attributes).with_context(context) }

        let(:organization) { create(:organization, available_locales: [:en]) }
        let(:participatory_space) { create(:participatory_process, organization:) }
        let(:component) { create(:vocdoni_component, participatory_space:) }
        let(:election) { nil }
        let(:context) { { current_organization: organization, current_component: component, election: } }

        let(:option_attributes) do
          {
            "0" => { title_en: "Yes" },
            "1" => { title_en: "No" }
          }
        end

        let(:question_attributes) do
          {
            "0" => {
              uid: "q0",
              title_en: "Do you agree?",
              description_en: "",
              answers: option_attributes
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

        it { is_expected.to be_valid }

        it "reads the whole ballot in one submit" do
          expect(form.questions.size).to eq(1)
          expect(form.questions.first.answers.size).to eq(2)
        end

        describe "questions" do
          context "when a question has a single option" do
            before { attributes[:election][:questions]["0"][:answers] = { "0" => { title_en: "Yes" } } }

            it "is refused: one option is not a choice" do
              expect(form).to be_invalid
            end
          end

          # The reported failure: the flash said "there was a problem saving the
          # questions" and nothing on the page said *which* field. With several
          # questions on one page that is a hunt.
          context "when one option is filled in and the other is left empty" do
            before do
              attributes[:election][:questions]["0"][:answers] = {
                "0" => { title_en: "Yes" },
                "1" => { title_en: "" }
              }
            end

            it { is_expected.to be_invalid }

            it "reports the empty option on the option itself" do
              form.invalid?

              blank_option = form.questions.first.answers.last

              expect(blank_option.errors[:title_en]).to be_present
            end

            it "still says on the question what the ballot is missing" do
              form.invalid?

              expect(form.questions.first.errors[:answers]).to be_present
            end

            it "keeps what the admin typed" do
              form.invalid?

              expect(form.questions.first.answers.first.title["en"]).to eq("Yes")
            end
          end

          context "when an option was added and left empty" do
            before { attributes[:election][:questions]["0"][:answers]["2"] = { title_en: "" } }

            it { is_expected.to be_valid }

            it "drops it instead of reporting it" do
              expect(form.questions.first.options.size).to eq(2)
            end

            it "does not flag a spare row on a question that is already valid" do
              form.valid?

              expect(form.questions.first.answers.last.errors).to be_empty
            end
          end

          context "when a whole question card was added and left empty" do
            before do
              attributes[:election][:questions]["1"] = {
                uid: "q1",
                title_en: "",
                description_en: "",
                answers: { "0" => { title_en: "" }, "1" => { title_en: "" } }
              }
            end

            it { is_expected.to be_valid }

            it "is not persisted" do
              expect(form.submitted_questions.size).to eq(1)
            end
          end

          # The reported failure: saving an untouched ballot answered with the
          # flash "There was a problem saving the questions." and no mark
          # anywhere on the page, so nothing said which of the fields in front
          # of the admin the flash was about.
          context "when every question is empty" do
            before { attributes[:election][:questions]["0"] = { uid: "q0", title_en: "", description_en: "", answers: {} } }

            it { is_expected.to be_invalid }

            it "says what the ballot is missing" do
              form.invalid?

              expect(form.ballot_error).to eq("Add at least one question: an election with nothing on the ballot has nothing to vote on.")
            end

            it "flags the first question so the page is not blank" do
              form.invalid?

              expect(form.questions.first.errors[:title_en]).to be_present
            end
          end

          context "when a question has options but no title" do
            before { attributes[:election][:questions]["0"][:title_en] = "" }

            it { is_expected.to be_invalid }
          end

          # The reported failure: "Audit" / "Audit" / "Budget" saved with
          # "Questions saved successfully". Once published that ballot offers
          # the same choice twice for ever, and the results show two rows with
          # nothing to tell them apart.
          describe "options that say the same thing" do
            before do
              attributes[:election][:questions]["0"][:answers] = {
                "0" => { title_en: "Audit" },
                "1" => { title_en: "Audit" },
                "2" => { title_en: "Budget" }
              }
            end

            it { is_expected.to be_invalid }

            it "says on the question why a ballot cannot carry them" do
              form.invalid?

              expect(form.questions.first.errors[:answers].join(" "))
                .to eq("Two of these options say the same thing: a voter cannot tell them apart on the ballot, and the " \
                       "results would show them as two identical rows. Reword one of them, or remove it. Options in " \
                       "different questions may repeat.")
            end

            it "flags both offending inputs and leaves the innocent one alone" do
              form.invalid?

              answers = form.questions.first.answers

              expect(answers[0].errors[:title_en]).to eq(["This option says the same as another one in this question."])
              expect(answers[1].errors[:title_en]).to eq(["This option says the same as another one in this question."])
              expect(answers[2].errors).to be_empty
            end
          end

          context "when two options differ only in case and surrounding space" do
            before do
              attributes[:election][:questions]["0"][:answers] = {
                "0" => { title_en: "Audit" },
                "1" => { title_en: "  audit " }
              }
            end

            it "is refused: a voter reads them as the same option" do
              expect(form).to be_invalid
            end
          end

          context "when two different questions offer the same option" do
            before do
              attributes[:election][:questions]["1"] = {
                uid: "q1",
                title_en: "Do you agree with the second thing?",
                description_en: "",
                answers: { "0" => { title_en: "Yes" }, "1" => { title_en: "No" } }
              }
            end

            it { is_expected.to be_valid }
          end

          # Empty rows are `enough_options`' business. Reporting a pile of them
          # as duplicates of each other would bury the message that helps.
          context "when several options are left empty" do
            before do
              attributes[:election][:questions]["0"][:answers] = {
                "0" => { title_en: "Yes" },
                "1" => { title_en: "No" },
                "2" => { title_en: "" },
                "3" => { title_en: "" }
              }
            end

            it { is_expected.to be_valid }
          end
        end

        # `#secret_until_the_end?` used to live on this form and was derived
        # from the ballot-wide `result_visibility`. Task 2 moved the setting
        # to `ElectionForm` (renamed to `results_availability`) and Task 3
        # dropped both attributes from this form.

        describe ".from_model" do
          subject(:form) { described_class.from_model(election).with_context(context) }

          let(:election) { create(:vocdoni_election, :with_questions, component:, questions_count: 2, answers_count: 3) }

          it "loads the whole ballot" do
            expect(form.questions.size).to eq(2)
            expect(form.questions.map { |question| question.answers.size }).to all(eq(3))
          end

          context "when the election has no questions yet" do
            let(:election) { create(:vocdoni_election, component:) }

            it "opens with one empty question so there is something to edit" do
              expect(form.questions.size).to eq(1)
              expect(form.questions.first.answers.size).to eq(2)
            end
          end
        end
      end
    end
  end
end
