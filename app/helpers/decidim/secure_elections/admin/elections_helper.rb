# frozen_string_literal: true

module Decidim
  module SecureElections
    module Admin
      # View helpers for the admin side.
      #
      # These only read local state. In particular nothing here ever asks the
      # Vocdoni API anything — status, turnout and completeness all come from
      # columns (ARCHITECTURE §0.5).
      module ElectionsHelper
        include Decidim::ApplicationHelper

        # One entry of the step navigation that sits above every admin screen of
        # a single election.
        #
        # `number` is nil for the monitor, which is not one of the five steps an
        # admin fills in but where they end up afterwards. `reason` is what a
        # locked entry says about itself: entries stay visible and explain
        # themselves rather than disappearing, so an admin can always see what
        # is left to do and why.
        NavItem = Struct.new(:key, :label, :icon, :path, :number, :enabled, :complete, :reason, keyword_init: true) do
          def enabled? = enabled.present?

          def complete? = complete.present?

          def numbered? = number.present?
        end

        # One icon per step of the wizard. Every name here is registered in
        # `Decidim::SecureElections::Engine` — Decidim 0.33 raises at render time on an
        # unregistered icon rather than falling back to a placeholder.
        STEP_ICONS = {
          details: "bill-line",
          questions: "question-answer-line",
          census: "group-2-line",
          calendar: "calendar-schedule-line",
          publish: "shield-check-line",
          monitor: "dashboard-line"
        }.freeze

        # The callout colour of each display state. Keyed by
        # `Election#display_state`, never by the raw upstream status.
        DISPLAY_STATE_CLASSES = {
          draft: "basic",
          publishing: "warning",
          scheduled: "secondary",
          ongoing: "success",
          paused: "warning",
          ended: "secondary",
          results: "secondary",
          canceled: "alert"
        }.freeze

        # The step navigation, in order.
        #
        # Every entry is rendered, always. A step whose prerequisites do not
        # hold is disabled and carries the reason with it, because an admin who
        # cannot open the census needs to be told that the ballot is unfinished,
        # not left clicking a link that does nothing.
        #
        # The reachability rule is not implemented here — it is
        # `Election#step_blocker`, which the controller guard and the permission
        # class ask as well.
        #
        # @param election [Decidim::SecureElections::Election]
        # @return [Array<NavItem>]
        def secure_elections_admin_nav_items(election)
          Decidim::SecureElections::Election::NAV_STEPS.map do |step|
            blocker = election.step_blocker(step)
            number = Decidim::SecureElections::Election::WIZARD_STEPS.index(step)&.succ

            NavItem.new(
              key: step,
              label: secure_elections_step_label(step),
              icon: STEP_ICONS.fetch(step),
              # A locked step leads nowhere: the guard would only bounce the
              # admin straight back, which reads as a broken link.
              path: blocker.nil? ? secure_elections_step_path(election, step) : "#",
              number:,
              enabled: blocker.nil?,
              complete: election.step_complete?(step),
              reason: blocker && vocdoni_step_reason(blocker)
            )
          end
        end

        # "Step 3 of 5" — where the admin is in the sequence. Nil on the
        # monitor, which is not one of the five steps.
        #
        # @param election [Decidim::SecureElections::Election]
        # @param current [Symbol, nil]
        # @return [String, nil]
        def vocdoni_step_progress(election, current)
          number = Decidim::SecureElections::Election::WIZARD_STEPS.index(current.to_s.to_sym)&.succ
          return nil if number.blank?

          t("decidim.secure_elections.admin.nav.progress",
            number:,
            total: Decidim::SecureElections::Election::WIZARD_STEPS.size,
            completed: election.completed_steps_count)
        end

        # @param step [Symbol]
        # @return [String]
        def secure_elections_step_label(step)
          # i18n-tasks-use t("decidim.secure_elections.admin.menu.details")
          # i18n-tasks-use t("decidim.secure_elections.admin.menu.questions")
          # i18n-tasks-use t("decidim.secure_elections.admin.menu.census")
          # i18n-tasks-use t("decidim.secure_elections.admin.menu.calendar")
          # i18n-tasks-use t("decidim.secure_elections.admin.menu.publish")
          # i18n-tasks-use t("decidim.secure_elections.admin.menu.monitor")
          t(step, scope: "decidim.secure_elections.admin.menu")
        end

        # @param blocker [Symbol] as returned by `Election#step_blocker`
        # @return [String]
        def vocdoni_step_reason(blocker)
          # i18n-tasks-use t("decidim.secure_elections.admin.nav.reasons.unsaved")
          # i18n-tasks-use t("decidim.secure_elections.admin.nav.reasons.not_on_chain")
          # i18n-tasks-use t("decidim.secure_elections.admin.nav.reasons.locked_on_chain")
          # i18n-tasks-use t("decidim.secure_elections.admin.nav.reasons.details_incomplete")
          # i18n-tasks-use t("decidim.secure_elections.admin.nav.reasons.questions_incomplete")
          # i18n-tasks-use t("decidim.secure_elections.admin.nav.reasons.census_incomplete")
          # i18n-tasks-use t("decidim.secure_elections.admin.nav.reasons.calendar_incomplete")
          t(blocker, scope: "decidim.secure_elections.admin.nav.reasons")
        end

        # Which step of the navigation the current screen belongs to.
        #
        # Derived from the controller, so that a screen cannot claim to be on a
        # step it is not. `explicit` is only a fallback for a caller that has no
        # controller of its own, and a few alternative step names are accepted
        # there for convenience.
        def vocdoni_nav_current_key(explicit = nil)
          key = vocdoni_nav_key_from_action
          return key if key.present?

          case explicit.to_s
          when "details", "editor" then :details
          when "questions" then :questions
          when "census" then :census
          when "calendar" then :calendar
          when "setup", "publish" then :publish
          when "monitor" then :monitor
          end
        end

        def secure_elections_question_type_options
          # i18n-tasks-use t("decidim.secure_elections.question_types.singlechoice")
          # i18n-tasks-use t("decidim.secure_elections.question_types.multichoice")
          Decidim::SecureElections::Question::QUESTION_TYPES.map do |type|
            [t(type, scope: "decidim.secure_elections.question_types"), type]
          end
        end

        # Above this many locales `Decidim::FormBuilder` swaps the language tabs
        # of a translatable field for a `<select>`. Verbatim from
        # `FormBuilder#create_language_selector`; there is no hook to ask.
        LANGUAGE_SELECT_THRESHOLD = 4

        # Names the per-field language switcher.
        #
        # `FormBuilder#language_selector_select` renders a bare
        # `<select class="language-change">` with no label of any kind, so on an
        # organization with more than four locales every translatable field is
        # preceded by an unnamed combobox — three of them per question card. The
        # field's own label cannot serve: the form builder gives it to the input
        # inside the tab panel.
        #
        # Below the threshold the same id belongs to a `<ul role="tablist">`,
        # which is not a labelable element and is announced by its own contents,
        # so nothing is rendered at all rather than a `for` pointing at a list.
        #
        # @param tabs_id [String] the `tabs_id` passed to `translated`
        # @param field [String] the human name of the field it switches
        # @return [ActiveSupport::SafeBuffer, nil]
        def secure_elections_language_selector_label(tabs_id, field)
          return unless secure_elections_language_selector_is_a_select?

          label_tag tabs_id,
                    t("decidim.secure_elections.admin.elections.editor.language_selector_label", field:),
                    class: "sr-only"
        end

        # The badge every admin screen leads with.
        #
        # It renders the *display* state, never the raw upstream status: a
        # process that is open and taking votes reports `ready`, which reads as
        # "not started yet" and made a live election look dormant across the
        # whole admin. The wording is the public side's own
        # (`decidim.secure_elections.elections.states`), so an administrator and a
        # participant looking at the same election read the same sentence.
        #
        # The upstream value is not hidden — see
        # {#vocdoni_upstream_status_label}, which the monitor's technical block
        # renders next to the process and chain ids, where it is genuinely
        # useful.
        def secure_elections_election_status_label(election)
          state = election.display_state

          content_tag(:span,
                      secure_elections_display_state_label(state),
                      class: "label #{DISPLAY_STATE_CLASSES.fetch(state, "basic")}")
        end

        # @param state [Symbol] as returned by `Election#display_state`
        # @return [String]
        def secure_elections_display_state_label(state)
          # i18n-tasks-use t("decidim.secure_elections.elections.states.draft")
          # i18n-tasks-use t("decidim.secure_elections.elections.states.publishing")
          # i18n-tasks-use t("decidim.secure_elections.elections.states.scheduled")
          # i18n-tasks-use t("decidim.secure_elections.elections.states.ongoing")
          # i18n-tasks-use t("decidim.secure_elections.elections.states.paused")
          # i18n-tasks-use t("decidim.secure_elections.elections.states.ended")
          # i18n-tasks-use t("decidim.secure_elections.elections.states.results")
          # i18n-tasks-use t("decidim.secure_elections.elections.states.canceled")
          t(state, scope: "decidim.secure_elections.elections.states")
        end

        # The raw status as Vocdoni reports it. Useful when an admin is talking
        # to support or reading the explorer, useless as a headline — so it is
        # only ever rendered inside the monitor's technical block.
        def vocdoni_upstream_status_label(election)
          # i18n-tasks-use t("decidim.secure_elections.statuses.draft")
          t(election.status, scope: "decidim.secure_elections.statuses", default: election.status.to_s)
        end

        # When voting started, or when it will.
        #
        # "Starts when published" is only true while the election is still
        # waiting to be published. Once it is on chain that sentence is a lie
        # that reads as "nothing is happening", so from that moment on this
        # says when it actually opened.
        def vocdoni_start_time_text(election)
          started = election.started_at

          return l(started, format: :decidim_short) if started.present?
          return t("decidim.secure_elections.admin.elections.editor.started_on_publication") if election.on_chain?
          return t("decidim.secure_elections.admin.elections.editor.manual_start_label") if election.manual_start?

          t("decidim.secure_elections.admin.elections.editor.starts_on_publication")
        end

        # When the local copy of the tally was last read from the chain.
        #
        # Every vote figure in the admin comes from `results_cache`, which a
        # background job fills in (ARCHITECTURE §0.5). Showing the count without
        # showing its age is what makes a stale "0" look like a lost ballot.
        def secure_elections_last_synced_text(election)
          return t("decidim.secure_elections.admin.monitor.show.never_synced") if election.results_synced_at.blank?

          t("decidim.secure_elections.admin.monitor.show.last_synced",
            time: l(election.results_synced_at, format: :decidim_short))
        end

        # The icon Decidim's confirm dialog shows for each monitor control. Its
        # default is a waste bin, which is wrong for three of the four actions
        # here — nothing is being deleted. Every name is registered in
        # `Engine::ICONS`.
        STATUS_CONFIRM_ICONS = {
          "ready" => "play-circle-line",
          "paused" => "pause-circle-line",
          "ended" => "stop-circle-line",
          "canceled" => "close-circle-line"
        }.freeze

        # What a monitor control asks before it does something to a live
        # election.
        #
        # Written per status rather than from one template with the status
        # interpolated: "set every question to Canceled" is how the change is
        # implemented, not what it does, and the four actions differ in the one
        # thing an admin needs to know before pressing — whether it can be
        # undone.
        #
        # Decidim's shared confirm dialog hard-codes its buttons as OK and
        # Cancel, and "Cancel" reads as an answer to a control called *Cancel
        # election*. Until that dialog takes button labels, each sentence names
        # both outcomes explicitly so that neither button has to be guessed.
        def vocdoni_status_confirm_data(status)
          # i18n-tasks-use t("decidim.secure_elections.admin.monitor.show.confirm.ready.body")
          # i18n-tasks-use t("decidim.secure_elections.admin.monitor.show.confirm.ready.title")
          # i18n-tasks-use t("decidim.secure_elections.admin.monitor.show.confirm.paused.body")
          # i18n-tasks-use t("decidim.secure_elections.admin.monitor.show.confirm.paused.title")
          # i18n-tasks-use t("decidim.secure_elections.admin.monitor.show.confirm.ended.body")
          # i18n-tasks-use t("decidim.secure_elections.admin.monitor.show.confirm.ended.title")
          # i18n-tasks-use t("decidim.secure_elections.admin.monitor.show.confirm.canceled.body")
          # i18n-tasks-use t("decidim.secure_elections.admin.monitor.show.confirm.canceled.title")
          scope = "decidim.secure_elections.admin.monitor.show.confirm.#{status}"

          {
            confirm: t("body", scope:),
            "confirm-title": t("title", scope:),
            "confirm-icon": STATUS_CONFIRM_ICONS.fetch(status, "error-warning-line")
          }
        end

        # What "Move to trash" asks before it takes an election off Decidim.
        #
        # Trashing is the most destructive control on the index and it used to
        # carry the weakest guard on it: one generic sentence, while the
        # *neighbouring* "Unpublish" already explained that an election running
        # on chain keeps accepting votes. The asymmetry was backwards.
        #
        # There is nothing this action can do to the blockchain — the process,
        # its questions and its tally stay there, public, whatever Decidim does
        # — and that is exactly why it has to be said out loud: an admin
        # reaching for the bin because a vote is going wrong is reaching for the
        # one control that cannot stop it, while removing the page voters need
        # to open their ballot. So the wording is written per state rather than
        # from one template: what an admin needs to know before pressing differs
        # completely between a draft that exists nowhere else and an election
        # that is open and taking votes.
        #
        # Same dialog and same constraints as the monitor controls
        # ({#vocdoni_status_confirm_data}): Decidim's shared confirm modal takes
        # a body, a title and an icon, and hard-codes its buttons as OK and
        # Cancel, so each sentence names both outcomes rather than leaving
        # either to be guessed.
        def vocdoni_trash_confirm_data(election)
          # i18n-tasks-use t("decidim.secure_elections.admin.elections.confirm_trash.draft.body")
          # i18n-tasks-use t("decidim.secure_elections.admin.elections.confirm_trash.draft.title")
          # i18n-tasks-use t("decidim.secure_elections.admin.elections.confirm_trash.on_chain.body")
          # i18n-tasks-use t("decidim.secure_elections.admin.elections.confirm_trash.on_chain.title")
          # i18n-tasks-use t("decidim.secure_elections.admin.elections.confirm_trash.voting_open.body")
          # i18n-tasks-use t("decidim.secure_elections.admin.elections.confirm_trash.voting_open.title")
          scope = "decidim.secure_elections.admin.elections.confirm_trash.#{vocdoni_trash_confirm_key(election)}"

          {
            confirm: t("body", scope:),
            "confirm-title": t("title", scope:),
            "confirm-icon": "delete-bin-line"
          }
        end

        # @param election [Decidim::SecureElections::Election]
        # @return [String] `draft`, `on_chain` or `voting_open`
        def vocdoni_trash_confirm_key(election)
          return "draft" unless election.on_chain?
          # `:ongoing` is the derived display state, not the upstream status: a
          # process that is open and taking votes reports `ready`, which reads
          # as "not started yet" and would have picked the mildest wording for
          # the most urgent case.
          return "voting_open" if election.display_state == :ongoing

          "on_chain"
        end

        # The upstream question statuses that name a lifecycle on their own. The
        # one that is missing is `ready`, which does not: see
        # {#vocdoni_question_display_state}.
        QUESTION_DISPLAY_STATES = {
          "ongoing" => :ongoing,
          "paused" => :paused,
          "ended" => :ended,
          "results" => :results,
          "canceled" => :canceled
        }.freeze

        # The badge next to each question on the monitor.
        #
        # Same wording and same colours as the election's own badge, because an
        # admin reading a page whose headline says "Voting open" should not find
        # "Ready" underneath it. "Ready" is the Vocdoni API's word for "on chain
        # and not stopped by anyone"; read as English it says the opposite of
        # what is happening — that the vote has not started.
        #
        # The upstream value is still available verbatim, in the monitor's
        # technical block ({#vocdoni_upstream_status_label}).
        def vocdoni_question_status_label(question)
          state = vocdoni_question_display_state(question)

          content_tag(:span,
                      secure_elections_display_state_label(state),
                      class: "label #{DISPLAY_STATE_CLASSES.fetch(state, "basic")}")
        end

        # @param question [Decidim::SecureElections::Question]
        # @return [Symbol] a key of `decidim.secure_elections.elections.states`
        def vocdoni_question_display_state(question)
          status = question.vocdoni_status.presence
          return :draft if status.blank?

          state = QUESTION_DISPLAY_STATES[status]
          return state if state

          # Only `ready` gets this far, and whether a ready question is actually
          # open is the calendar's answer — exactly as it is for the election as
          # a whole, which is why the same derivation answers it.
          Decidim::SecureElections::ElectionStatusCell.state_for(question.election)
        end

        def vocdoni_turnout_text(election)
          return t("decidim.secure_elections.admin.monitor.turnout_unknown") if election.turnout.nil?

          t("decidim.secure_elections.admin.monitor.turnout_value",
            percent: number_to_percentage(election.turnout, precision: 1),
            votes: election.votes_count,
            census: election.census_size)
        end

        # The direct voting link — the one an organiser actually emails out.
        #
        # It is the same link the Vote button on the election page follows,
        # built by the same object, with one difference: no `exit`. A voter who
        # opens this from their inbox has no election page behind them to go
        # back to, and leaving it out is what keeps the link short enough to
        # paste into a message.
        #
        # Absolute, because it is going into somebody else's inbox. Nil when the
        # election is not on chain yet — there is then no process to open.
        def secure_elections_direct_voting_url(election)
          path = Decidim::SecureElections::VotingPageUrl.build(election, locale: I18n.locale)

          return if path.blank?

          "#{request.base_url}#{path}"
        end

        # Why the election can no longer be edited, in one sentence.
        def vocdoni_locked_reason(election)
          return nil if election.editable?

          t("decidim.secure_elections.admin.nav.locked_on_chain")
        end

        # Which navigation entry each wizard controller lights up. A controller
        # that is not a wizard step is absent on purpose: it lights up nothing
        # rather than falling back to the first step.
        NAV_KEY_BY_CONTROLLER = {
          "elections" => :details,
          "questions" => :questions,
          "census" => :census,
          "calendar" => :calendar,
          "setup" => :publish,
          "monitor" => :monitor
        }.freeze

        private

        def vocdoni_nav_key_from_action
          NAV_KEY_BY_CONTROLLER[controller_name]
        end

        # `FormBuilder#locales`, verbatim: the current locale is counted even
        # when the organization does not offer it.
        def secure_elections_language_selector_is_a_select?
          locales = if respond_to?(:available_locales)
                      Set.new([current_locale] + available_locales).to_a
                    else
                      Decidim.available_locales
                    end

          locales.count > LANGUAGE_SELECT_THRESHOLD
        end
      end
    end
  end
end
