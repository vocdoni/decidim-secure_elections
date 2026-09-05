# frozen_string_literal: true

module Decidim
  module SecureElections
    module Admin
      # Server-side enforcement of the wizard order.
      #
      # A disabled link is not access control. The navigation greys out the
      # steps an admin cannot open yet and says why, but the only thing that
      # actually stops a typed URL, a stale bookmark or a replayed form is this
      # concern: every screen that belongs to a step declares which one, and a
      # request for a step whose prerequisites do not hold is redirected to the
      # furthest step the admin *can* work on, with a flash explaining what is
      # missing.
      #
      # The rule itself lives on the model (`Election#step_blocker`), so this,
      # the navigation and `Decidim::SecureElections::Admin::Permissions` cannot drift
      # apart.
      #
      # Why the refusal is here and not only in the permission class: that class
      # may only ever `allow!`. The space and admin permission classes grant
      # broadly to administrators, and Decidim raises
      # `PermissionCannotBeDisallowedError` as soon as a later class allows what
      # an earlier one disallowed — see the comment at the top of
      # `app/permissions/decidim/secure_elections/admin/permissions.rb`. The permission
      # class therefore only withholds its grant; the hard refusal is this
      # redirect.
      module WizardStep
        extend ActiveSupport::Concern

        included do
          helper_method :secure_elections_step_path, :current_wizard_step
        end

        class_methods do
          # Declares which step of the wizard this controller's screens belong
          # to, and installs the guard.
          #
          # @param step [Symbol] one of `Election::NAV_STEPS`
          # @param options [Hash] passed straight to `before_action`, so a
          #   controller with screens outside the wizard (the election index,
          #   the trash) can limit the guard with `only:`.
          # @return [void]
          # Named rather than anonymous (`**`) on purpose: this is the DSL every
          # wizard controller calls, and the name is what tells a reader what
          # may go in there without opening this file.
          def wizard_step(step, **options) # rubocop:disable Style/ArgumentsForwarding
            @wizard_step = step
            before_action(:ensure_step_reachable!, **options) # rubocop:disable Style/ArgumentsForwarding
          end

          # @return [Symbol, nil]
          def declared_wizard_step
            return @wizard_step if @wizard_step
            return nil unless superclass.respond_to?(:declared_wizard_step)

            superclass.declared_wizard_step
          end
        end

        private

        # @return [Symbol, nil]
        def current_wizard_step
          self.class.declared_wizard_step
        end

        # @return [void]
        def ensure_step_reachable!
          step = current_wizard_step
          return if step.blank?

          # No election in scope means there is no step to guard — `new` and
          # `create` are reached before the record exists.
          current = wizard_election
          return if current.blank?

          blocker = current.step_blocker(step)
          return if blocker.blank?

          flash[:alert] = wizard_blocker_message(blocker)
          redirect_to secure_elections_step_path(current, current.furthest_reachable_step)
        end

        # The election the guard applies to, or nil when the action does not
        # have one. Subclasses expose it under different parameter names
        # (`:id` on the elections controller, `:election_id` everywhere else),
        # so this only asks for the reader they all define.
        #
        # @return [Decidim::SecureElections::Election, nil]
        def wizard_election
          return nil unless respond_to?(:election, true)

          election
        rescue ActiveRecord::RecordNotFound
          nil
        end

        # @param blocker [Symbol] as returned by `Election#step_blocker`
        # @return [String]
        def wizard_blocker_message(blocker)
          # i18n-tasks-use t("decidim.secure_elections.admin.nav.reasons.unsaved")
          # i18n-tasks-use t("decidim.secure_elections.admin.nav.reasons.not_on_chain")
          # i18n-tasks-use t("decidim.secure_elections.admin.nav.reasons.locked_on_chain")
          # i18n-tasks-use t("decidim.secure_elections.admin.nav.reasons.details_incomplete")
          # i18n-tasks-use t("decidim.secure_elections.admin.nav.reasons.questions_incomplete")
          # i18n-tasks-use t("decidim.secure_elections.admin.nav.reasons.census_incomplete")
          # i18n-tasks-use t("decidim.secure_elections.admin.nav.reasons.calendar_incomplete")
          I18n.t(blocker, scope: "decidim.secure_elections.admin.nav.reasons")
        end

        # Where a step lives. The single place that maps a step name onto a
        # route, used by the guard, the navigation and every "continue" button.
        #
        # @param election [Decidim::SecureElections::Election]
        # @param step [Symbol, String]
        # @return [String]
        def secure_elections_step_path(election, step)
          case step.to_sym
          when :questions then edit_election_questions_path(election)
          when :census then election_census_path(election)
          # `:publish` and `:monitor` both fold into the Dashboard tab now,
          # so any step key that used to point at either lands there.
          when :publish, :monitor then election_dashboard_path(election)
          # Everything else — `:details`, `:main`, `:calendar` (the
          # calendar step is folded into the Main tab), and any
          # unrecognised key — lands on the Main tab.
          else edit_election_path(election)
          end
        end
      end
    end
  end
end
