# frozen_string_literal: true

module Decidim
  module SecureElections
    module Admin
      # Step 5 of the wizard: the point of no return.
      #
      # Submitting this form enqueues the job that writes the election to the
      # blockchain. There is no undo, no edit and no delete afterwards, so the
      # form demands an explicit acknowledgement and re-checks every
      # precondition server-side.
      class SetupForm < Decidim::Form
        mimic :setup

        attribute :confirm_irreversible, Boolean, default: false

        validates :confirm_irreversible, acceptance: true
        validate :election_is_off_chain
        validate :details_are_complete
        validate :questions_are_complete
        validate :census_is_configured
        validate :calendar_is_complete
        validate :module_is_configured

        def election
          @election ||= context[:election]
        end

        private

        def election_is_off_chain
          return if election&.editable?

          errors.add(:base, I18n.t("decidim.secure_elections.admin.setup.errors.already_on_chain"))
        end

        def details_are_complete
          return if election&.details_complete?

          errors.add(:base, I18n.t("decidim.secure_elections.admin.setup.errors.details_incomplete"))
        end

        def questions_are_complete
          return if election&.questions_complete?

          errors.add(:base, I18n.t("decidim.secure_elections.admin.setup.errors.questions_incomplete"))
        end

        # The single most important check in this module.
        def census_is_configured
          return if election&.census_complete?

          errors.add(:base, I18n.t("decidim.secure_elections.admin.setup.errors.census_incomplete"))
        end

        def calendar_is_complete
          return if election&.calendar_complete?

          errors.add(:base, I18n.t("decidim.secure_elections.admin.setup.errors.calendar_incomplete"))
        end

        def module_is_configured
          return if Decidim::SecureElections.configured?

          errors.add(:base, I18n.t("decidim.secure_elections.admin.setup.errors.not_configured"))
        end
      end
    end
  end
end
