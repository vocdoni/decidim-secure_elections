# frozen_string_literal: true

module Decidim
  module SecureElections
    module Admin
      # One option of a question, nested inside `ElectionQuestionsForm`.
      #
      # `value` — the integer actually encoded in the ballot — is deliberately
      # absent: it is derived from the option's position by the command and is
      # never taken from the browser.
      class AnswerForm < Decidim::Form
        mimic :answer

        include Decidim::TranslatableAttributes

        translatable_attribute :title, String

        # Client-side identity of the row. The editor adds and removes options
        # without a page reload, so a brand new option has no `id` yet; the
        # autosave response uses this to hand back the database id it was given.
        # It is compared, never persisted.
        attribute :uid, String

        # Soft-delete flag set by the Remove button. A deleted option is excluded
        # from `options` in `QuestionForm` and is therefore destroyed by the
        # save command's `where.not(id: kept).destroy_all`.
        attribute :deleted, Boolean, default: false

        # An option the admin added and left empty is discarded rather than
        # reported. Clicking "Add a new option" one time too many is not a
        # mistake worth an error message, and the question still refuses to be
        # saved with fewer than two real options. An option filled in *some*
        # languages but not the organization's own is still an error, which is
        # what `translatable_presence` checks.
        validates :title, translatable_presence: true, unless: :unfilled?

        def unfilled?
          title.values.all?(&:blank?)
        end
      end
    end
  end
end
