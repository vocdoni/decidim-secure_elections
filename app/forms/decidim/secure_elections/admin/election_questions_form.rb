# frozen_string_literal: true

module Decidim
  module SecureElections
    module Admin
      # The Questions tab: the ballot.
      #
      # Questions **and** their options are on this one form: adding an option
      # must not cost a page load, so the options are nested attributes of the
      # questions, which are nested attributes of this form, and the whole
      # ballot arrives in a single submit.
      #
      # `question_type` is now per-question (on `QuestionForm`) — the old
      # ballot-wide copy that was duplicated down to every question has been
      # removed. `result_visibility` has moved to `ElectionForm` (the Main tab).
      class ElectionQuestionsForm < Decidim::Form
        mimic :election

        include Decidim::TranslatableAttributes

        attribute :questions, [QuestionForm]

        validate :at_least_one_question

        def map_model(election)
          self.questions = election.questions.map { |question| QuestionForm.from_model(question) }
          ensure_default_questions!
        end

        def election
          @election ||= context[:election]
        end

        def editable?
          election.nil? || election.editable?
        end

        # The questions that will actually be persisted. A card the admin added
        # and left completely empty is dropped instead of being reported, the
        # same way an empty option is. Cards the admin marked for deletion via
        # the Remove button are also excluded — the command destroys them.
        def submitted_questions
          questions.reject { |q| q.unfilled? || q.deleted }
        end

        # The database ids the browser does not know about yet, keyed by the
        # client-side identity of each row.
        #
        # @return [Hash] `{ "q0" => { "id" => 5, "answers" => { "q0-a0" => 9 } } }`
        def saved_ids
          submitted_questions.each_with_object({}) do |question, acc|
            next if question.uid.blank?

            acc[question.uid] = {
              "id" => question.id,
              "answers" => question.options.each_with_object({}) do |answer, answers|
                answers[answer.uid] = answer.id if answer.uid.present?
              end
            }
          end
        end

        # The one ballot-level sentence worth putting above the questions.
        #
        # `errors[:questions]` cannot simply be rendered: the form object adds a
        # bare `:invalid` to the parent whenever *any* nested question fails,
        # which would put "is invalid" at the top of the page every time a
        # single option was left empty three cards down — precisely the
        # unhelpful noise this screen exists to get rid of. Only the message
        # about the ballot as a whole belongs here; everything else is already
        # reported on the input it belongs to.
        #
        # @return [String, nil]
        def ballot_error
          errors.where(:questions, :blank).first&.message
        end

        # Makes sure the editor always has something to edit. A brand new
        # ballot opens with one question and two empty options, exactly like
        # upstream decidim-elections.
        def ensure_default_questions!
          self.questions = [QuestionForm.blank_question] if questions.blank?
          self
        end

        private

        # A ballot with nothing on it is refused, and the *input* that would fix
        # it says so.
        #
        # An untouched card is dropped rather than reported (`QuestionForm#
        # unfilled?`), which is right when there is another question to save and
        # wrong when there is not: saving an untouched page answered with a lone
        # flash left the admin looking at a screen with no mark on it anywhere,
        # wondering which of the fields in front of them the flash meant.
        def at_least_one_question
          return if submitted_questions.any?

          errors.add(:questions, :blank)

          # Only the first card. The admin is shown where to start, not scolded
          # for every empty question on the page.
          questions.first&.flag_empty!
        end
      end
    end
  end
end
