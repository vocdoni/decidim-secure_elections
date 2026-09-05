# frozen_string_literal: true

module Decidim
  module SecureElections
    module Admin
      # One question of the ballot step, nested inside
      # `ElectionQuestionsForm` together with its options.
      #
      # Remember that each question becomes its own Vochain election once the
      # process is published (ARCHITECTURE §1), which is why the options carry a
      # contiguous 0-based value and why a question with fewer than two of them
      # is refused.
      #
      # `question_type` lives here because the database keeps it per question
      # (ARCHITECTURE §4d), but the editor exposes a single control that sets it on
      # every question at once, the way the Vocdoni app does. The parent form
      # copies its value down before validating, so nothing coming from the
      # browser can give two questions of the same process different types.
      class QuestionForm < Decidim::Form
        mimic :question

        include Decidim::TranslatableAttributes

        # A ballot with a single option is not a choice.
        MINIMUM_OPTIONS = 2

        translatable_attribute :title, String
        translatable_attribute :description, String

        # Client-side identity of the card, so that the autosave response can
        # hand back the database id of a question that did not exist yet. It is
        # compared, never persisted.
        attribute :uid, String
        attribute :question_type, String, default: "singlechoice"
        attribute :max_choices, Integer
        attribute :min_choices, Integer
        attribute :answers, [AnswerForm]
        attribute :deleted, Boolean, default: false

        validates :question_type, inclusion: { in: Decidim::SecureElections::Question::QUESTION_TYPES }
        validates :title, translatable_presence: true, unless: :unfilled?
        validates :min_choices,
                  numericality: { only_integer: true, greater_than: 0 },
                  allow_blank: true,
                  if: :multichoice?
        validates :max_choices,
                  numericality: { only_integer: true, greater_than: 0 },
                  allow_blank: true,
                  if: :multichoice?
        validate :enough_options, unless: :unfilled?
        validate :distinct_options, unless: :unfilled?
        validate :choice_bounds, unless: :unfilled?

        # The question the editor starts with: a title, no description and the
        # two empty options every ballot needs at a minimum.
        def self.blank_question
          new(answers: Array.new(MINIMUM_OPTIONS) { AnswerForm.new })
        end

        def map_model(question)
          self.answers = question.answers.map { |answer| AnswerForm.from_model(answer) }
        end

        def multichoice?
          question_type == "multichoice"
        end

        # A card the admin added and then left completely alone. It is dropped
        # on save instead of being reported as invalid — clicking "Add
        # question" one time too many is not a mistake worth an error message.
        def unfilled?
          title.values.all?(&:blank?) && description.values.all?(&:blank?) && options.empty?
        end

        # The options that will actually be persisted, in the order the admin
        # arranged them. Empty rows and rows the admin removed (deleted) are
        # dropped — the command destroys the deleted ones.
        def options
          answers.reject { |a| a.unfilled? || a.deleted }
        end

        # How many options will be saved. Used by the per-question max_choices
        # select to constrain the range offered.
        def number_of_options
          answers.size
        end

        # Choice bounds are meaningless for a single-choice question — upstream
        # ignores `typeSetup` for `singlechoice` entirely — so they are dropped
        # rather than rejected. Rejecting them was worse than useless: the
        # multichoice fieldset stays in the DOM when the type changes, so anyone
        # who set a bound and then switched back to single choice got "is
        # invalid" reported against a field they had just set correctly.
        def min_choices
          multichoice? ? super : nil
        end

        def max_choices
          multichoice? ? super : nil
        end

        # An untouched card is normally dropped rather than reported. When it is
        # the *only* card, dropping it leaves a ballot with nothing on it, and
        # the parent form asks for the one input that would fix that to say so —
        # otherwise a page that is entirely empty answers an empty submit with
        # nothing but a flash.
        def flag_empty!
          errors.add(:"title_#{title_locale_suffix}", :blank)
        end

        private

        # A question that does not offer a choice is refused, and the *inputs*
        # that would fix it say so.
        #
        # An empty option is dropped rather than reported when the question is
        # otherwise fine — clicking "Add a new option" one time too many is not
        # a mistake. But when dropping them leaves the question below the
        # minimum, the blank rows are no longer spare, they are the problem, and
        # a lone flash saying "there was a problem saving the questions" turns
        # a ballot with several questions into a hunt.
        #
        # Only as many rows as it takes to reach the minimum are flagged: the
        # admin is shown what to fill in, not scolded for every blank row on the
        # page.
        def enough_options
          missing = MINIMUM_OPTIONS - options.size
          return if missing <= 0

          errors.add(:answers, :too_short, count: MINIMUM_OPTIONS)

          answers.select(&:unfilled?).first(missing).each { |answer| flag_blank(answer) }
        end

        # Two options a voter cannot tell apart are refused.
        #
        # Saving them was silent, and the ballot they produce is permanent: the
        # voting page shows the same words twice, and the results show two identical
        # rows with nothing to say which is which. There is no fixing that after
        # publication, so it has to be caught here.
        #
        # Compared on the organization's own locale — the one every option is
        # required to carry, and the one a voter of that organization reads —
        # case-insensitively and with the surrounding whitespace gone, because
        # "Audit" and "audit " are the same option on a ballot paper.
        #
        # Only within one question: two questions may perfectly well both offer
        # "Yes".
        def distinct_options
          grouped = options.group_by { |answer| comparable_title(answer) }
          clashing = grouped.values.reject { |group| group.size < 2 }.flatten

          return if clashing.empty?

          errors.add(:answers, :duplicated)
          clashing.each { |answer| flag_duplicate(answer) }
        end

        # Blank titles are not compared: they are `enough_options`' business,
        # and reporting a pile of empty rows as duplicates of each other would
        # bury the message that actually helps.
        def comparable_title(answer)
          answer.title[default_locale_tag(answer)].to_s.strip.downcase.presence
        end

        # Reported against the translated attribute the field actually renders,
        # the same one `translatable_presence` writes to, so the error lands on
        # the input rather than in a summary nobody reads.
        def flag_blank(answer)
          answer.errors.add(:"title_#{title_locale_suffix(answer)}", :blank)
        end

        # The message is passed as a String rather than as an error type: the
        # attribute carries the locale in its name (`title_en`, `title_ca`), so
        # a type would need one translation key per locale, and every locale but
        # English is Crowdin's. A String is the same message wherever it lands.
        def flag_duplicate(answer)
          answer.errors.add(
            :"title_#{title_locale_suffix(answer)}",
            I18n.t("decidim.secure_elections.admin.elections.editor.duplicate_option")
          )
        end

        # `TranslatablePresenceValidator`'s own rule, verbatim, including the
        # doubled underscore it uses for a hyphenated locale — the attribute
        # name has to be the one the field renders or the error is invisible.
        def title_locale_suffix(form = self)
          default_locale_tag(form).gsub("-", "__")
        end

        # The organization's default locale, as it is keyed in a translatable
        # attribute (`ca-ES`, not `ca__ES`).
        def default_locale_tag(form = self)
          locale = form.try(:default_locale).presence ||
                   form.try(:current_organization)&.default_locale ||
                   current_organization&.default_locale ||
                   Decidim.default_locale

          locale.to_s
        end

        # The two selection limits have to agree with each other *and* with the
        # ballot they are measured against, and when they do not, the admin has
        # to be told which number to change and why.
        #
        # A bare "is invalid" on the maximum said neither. It never named the
        # minimum it contradicted, never mentioned how many options the question
        # actually offers, and left the minimum — frequently the number that is
        # out of range — unflagged, so the one input the admin had to touch was
        # the one input that looked fine.
        #
        # Every number that is wrong is now flagged on its own input, with the
        # reason it is wrong. At most one message per field, tightest constraint
        # first: the option count is an absolute ceiling, so it is reported
        # ahead of the relation between the two numbers, which the admin has to
        # satisfy anyway once both fit.
        def choice_bounds
          return unless multichoice?

          available = options.size

          flag_min_choices(available)
          flag_max_choices(available)
        end

        def flag_min_choices(available)
          return if min_choices.blank?

          if available.positive? && min_choices > available
            errors.add(:min_choices, :more_than_options, count: available)
          elsif max_choices.present? && min_choices > max_choices
            errors.add(:min_choices, :more_than_max, max: max_choices)
          end
        end

        def flag_max_choices(available)
          return if max_choices.blank?

          if available.positive? && max_choices > available
            errors.add(:max_choices, :more_than_options, count: available)
          elsif min_choices.present? && max_choices < min_choices
            errors.add(:max_choices, :less_than_min, min: min_choices)
          end
        end
      end
    end
  end
end
