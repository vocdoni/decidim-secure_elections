# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Authorization for the admin side of the Vocdoni component.
      #
      # The recurring rule is `election.editable?` — that is, "the process does
      # not exist on chain yet". Once it does, every mutating action is refused
      # here as well as in the commands, because the on-chain payload can no
      # longer be changed and an editable Decidim record would simply be lying
      # to the admin.
      #
      # Why this class only ever grants, and never vetoes
      # ------------------------------------------------
      # A component permission class runs *first* in the chain, followed by the
      # space and then `Decidim::Admin::Permissions`. Both of those grant broadly
      # to administrators — `ParticipatoryProcesses::Permissions#collaborator_action?`
      # allows every `:read` inside a process, and the admin permissions allow a
      # range of management actions. Decidim raises
      # `PermissionCannotBeDisallowedError` the moment a later class allows what
      # an earlier one disallowed, so a `toggle_allow(false)` here does not
      # produce "denied" — it produces a 500 on any page that renders the
      # control.
      #
      # Every rule therefore uses `allow! if …`: grant when the condition holds,
      # otherwise stay silent and let the rest of the chain decide. Nothing is
      # lost, because the invariants that actually matter — a census that
      # identifies somebody, and the irreversibility of an on-chain process —
      # are enforced again in the commands and jobs, which is where they belong.
      #
      # The wizard order
      # ----------------
      # A step is reachable only when every step before it is complete. That is
      # asked here through `Election#step_reachable?`, the same method the
      # navigation and `Decidim::Elections::Vocdoni::Admin::WizardStep` use, so the three
      # cannot drift apart. This class is the *third* net, not the first: the
      # hard refusal — a redirect to the furthest reachable step, with a flash
      # saying what is missing — is in the controller concern, precisely because
      # this class may not veto.
      class Permissions < Decidim::DefaultPermissions
        def permissions
          return permission_action unless user
          return permission_action unless permission_action.scope == :admin

          allowed_election_action?
          allowed_question_action?
          allowed_answer_action?
          allowed_census_action?
          allowed_calendar_action?
          allowed_setup_action?
          allowed_monitor_action?

          permission_action
        end

        private

        def election
          @election ||= context.fetch(:election, nil)
        end

        def question
          @question ||= context.fetch(:question, nil)
        end

        def trashable_deleted_resource
          @trashable_deleted_resource ||= context.fetch(:trashable_deleted_resource, nil)
        end

        def allowed_election_action?
          return false unless permission_action.subject == :election

          case permission_action.action
          when :read, :create, :manage_trash
            allow!
          when :update
            allow! if election.present? && election.editable?
          when :publish
            allow! if election.present? && !election.published? && election.questions.exists?
          when :unpublish
            allow! if election.present? && election.published?
          when :soft_delete
            # A live process keeps accepting votes no matter what Decidim does
            # with its copy, so an election can only be trashed before it goes
            # on chain or after it is over.
            allow! if trashable_deleted_resource.present? && (trashable_deleted_resource.editable? || trashable_deleted_resource.finished?)
          when :restore
            allow! if trashable_deleted_resource.present?
          end
        end

        # Step 2. Readable as soon as the details are in place — and afterwards
        # for ever, read-only, once the process is on chain.
        def allowed_question_action?
          return false unless permission_action.subject == :question

          case permission_action.action
          when :read
            allow! if election.present? && election.step_reachable?(:questions)
          when :create, :update, :destroy
            allow! if election.present? && election.editable? && election.step_reachable?(:questions)
          end
        end

        def allowed_answer_action?
          return false unless permission_action.subject == :answer

          case permission_action.action
          when :create, :update, :destroy
            allow! if question.present? && question.editable?
          end
        end

        # Step 3.
        def allowed_census_action?
          return false unless permission_action.subject == :census

          case permission_action.action
          when :read
            allow! if election.present? && election.step_reachable?(:census)
          when :update
            allow! if election.present? && election.editable? && election.step_reachable?(:census)
          end
        end

        # Step 4.
        def allowed_calendar_action?
          return false unless permission_action.subject == :calendar

          case permission_action.action
          when :read
            allow! if election.present? && election.step_reachable?(:calendar)
          when :update
            allow! if election.present? && election.editable? && election.step_reachable?(:calendar)
          end
        end

        # Step 5.
        def allowed_setup_action?
          return false unless permission_action.subject == :setup

          case permission_action.action
          when :read
            # `step_reachable?(:publish)` is false once the process is on chain,
            # because the step is over. The controller guard sends that case to
            # the monitor before the action runs; the extra `on_chain?` here
            # only keeps the grant honest for anything that asks directly.
            allow! if election.present? && (election.on_chain? || election.step_reachable?(:publish))
          when :create
            # The irreversible one. Everything has to be in place, including a
            # census that actually identifies somebody.
            allow! if election.present? && election.ready_for_setup? && Decidim::Elections::Vocdoni.configured?
          end
        end

        def allowed_monitor_action?
          return false unless permission_action.subject == :monitor

          case permission_action.action
          when :read, :refresh
            # Readable from the moment publication is attempted: this page is where
            # an admin watches the on-chain publish land, or sees why it failed.
            allow! if election.present? && election.step_reachable?(:monitor)
          when :update_status
            allow! if election.present? && election.on_chain? && !election.canceled?
          end
        end
      end
    end
  end
end
end
