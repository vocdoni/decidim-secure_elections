# frozen_string_literal: true

module Decidim
  module SecureElections
    module Admin
      # The Dashboard tab: a single page that branches on the election's
      # on-chain state.
      #
      # **Pre-publish (editable):** renders the completeness checklist, read-only
      # summary cards for Main / Questions / Census, and the sticky
      # confirm_irreversible + "Publish on the blockchain" form. The six
      # SetupForm validators remain the server-side guard.
      #
      # **Post-publish (on-chain or publishing):** renders the status card,
      # calendar, and live-refresh results monitor — the view the old
      # MonitorController served, now unified here.
      #
      # `show` also answers `.json` requests for the monitor pack's poll cycle,
      # exactly as `monitor#show` did.
      class DashboardController < Admin::ApplicationController
        include ActionView::Helpers::NumberHelper

        helper_method :questions

        def show
          enforce_permission_to(:read, :setup, election:)

          # Instantiate SetupForm whenever the election is still editable
          # (draft OR publishing OR failed). `_publish.html.erb` reads
          # `form.expected_phrase`/`form.errors` and handles the publishing
          # state internally by disabling controls; skipping the assignment
          # when `publishing?` produced a nil form that decidim_form_for
          # rejected as "First argument … cannot be nil".
          @form = form(Decidim::SecureElections::Admin::SetupForm).instance(election:) if election.editable?

          respond_to do |format|
            format.html
            format.json { render json: monitor_payload }
          end
        end

        # Receives the SetupForm submission and enqueues the blockchain write.
        # Preserves the exact semantics of the old SetupController#create +
        # SetupElection command; the command is deleted, its behaviour lives here.
        def publish
          enforce_permission_to(:create, :setup, election:)

          @form = form(Decidim::SecureElections::Admin::SetupForm).from_params(params, election:)

          # Guard against `@form.valid?` implicitly requiring the object,
          # and against the render-action "show" fallback which reuses the
          # partial that dereferences `form.errors`.
          @form ||= form(Decidim::SecureElections::Admin::SetupForm).instance(election:)

          if @form.valid?
            ActiveRecord::Base.transaction do
              Decidim.traceability.perform_action!(
                :setup,
                election,
                current_user,
                visibility: "all"
              ) do
                election.update!(
                  status: "publishing",
                  results_cache: election.results_cache.to_h.except("error")
                )
                election
              end
            end

            # Enqueued outside the transaction so the worker cannot observe a
            # row that has not been committed yet.
            Decidim::SecureElections::PublishElectionJob.perform_later(election.id)

            flash[:notice] = I18n.t("setup.create.success", scope: "decidim.secure_elections.admin")
            redirect_to election_dashboard_path(election)
          else
            flash.now[:alert] = I18n.t("setup.create.invalid", scope: "decidim.secure_elections.admin")
            render action: "show", status: :unprocessable_content
          end
        end

        # Hides the election from the public site (reversible Decidim visibility).
        def unpublish
          enforce_permission_to(:unpublish, :election, election:)

          Decidim::SecureElections::Admin::UnpublishElection.call(election, current_user) do
            on(:ok) do
              flash[:notice] = I18n.t("elections.unpublish.success", scope: "decidim.secure_elections.admin")
              redirect_to election_dashboard_path(election)
            end

            on(:invalid) do
              flash[:alert] = I18n.t("elections.unpublish.invalid", scope: "decidim.secure_elections.admin")
              redirect_to election_dashboard_path(election)
            end
          end
        end

        # Transitions a born-paused election from PAUSED → READY on chain.
        # Only available when `manual_start? && paused?`.
        def start
          enforce_permission_to(:update_status, :monitor, election:)

          @form = form(Decidim::SecureElections::Admin::QuestionStatusForm).from_params(
            { question_status: { status: "ready" } },
            election:
          )

          Decidim::SecureElections::Admin::UpdateQuestionStatus.call(@form, current_user) do
            on(:ok) do
              flash[:notice] = I18n.t("dashboard.start.success", scope: "decidim.secure_elections.admin")
              redirect_to election_dashboard_path(election)
            end

            on(:invalid) do
              flash[:alert] = I18n.t("dashboard.start.invalid", scope: "decidim.secure_elections.admin")
              redirect_to election_dashboard_path(election)
            end
          end
        end

        # Enqueues a sync job to pull fresh tally data from the blockchain.
        # Mirrors MonitorController#refresh — same command, same flash, new home.
        def refresh
          enforce_permission_to(:refresh, :monitor, election:)

          enqueued = false
          message = nil

          Decidim::SecureElections::Admin::RefreshElection.call(election) do
            on(:ok) do |mode|
              # i18n-tasks-use t("decidim.secure_elections.admin.monitor.refresh.publish")
              # i18n-tasks-use t("decidim.secure_elections.admin.monitor.refresh.results")
              enqueued = true
              message = I18n.t("monitor.refresh.#{mode}", scope: "decidim.secure_elections.admin")
            end

            on(:invalid) do
              message = I18n.t("monitor.refresh.invalid", scope: "decidim.secure_elections.admin")
            end
          end

          respond_to do |format|
            format.html do
              flash[enqueued ? :notice : :alert] = message
              redirect_to election_dashboard_path(election)
            end

            # No redirect for the monitor pack: it stays on the page and polls
            # `show.json` until the sync job lands.
            format.json do
              render json: { enqueued:, message:, synced_at: election.results_synced_at&.iso8601 },
                     status: enqueued ? :accepted : :unprocessable_content
            end
          end
        end

        # Changes the on-chain status of every question (or a subset).
        # Mirrors MonitorController#status — same form, same command, new home.
        def status
          enforce_permission_to(:update_status, :monitor, election:)

          @form = form(Decidim::SecureElections::Admin::QuestionStatusForm).from_params(params, election:)

          Decidim::SecureElections::Admin::UpdateQuestionStatus.call(@form, current_user) do
            on(:ok) do
              flash[:notice] = I18n.t("monitor.status.success", scope: "decidim.secure_elections.admin")
              redirect_to election_dashboard_path(election)
            end

            on(:invalid) do
              flash.now[:alert] = I18n.t("monitor.status.invalid", scope: "decidim.secure_elections.admin")
              render action: "show", status: :unprocessable_content
            end
          end
        end

        private

        def questions
          @questions ||= election.questions.includes(:answers)
        end

        # The monitor payload the JS pack polls for live updates. Local reads
        # only — no upstream call ever happens inside a web request.
        def monitor_payload
          {
            id: election.id,
            state: election.display_state,
            state_label: helpers.secure_elections_display_state_label(election.display_state),
            upstream_status: helpers.vocdoni_upstream_status_label(election),
            votes_count: election.votes_count,
            census_size: election.census_size,
            turnout_text: helpers.vocdoni_turnout_text(election),
            synced_at: election.results_synced_at&.iso8601,
            synced_text: helpers.secure_elections_last_synced_text(election),
            questions: questions.map { |question| question_payload(question) }
          }
        end

        def question_payload(question)
          {
            id: question.id,
            votes_text: t("decidim.secure_elections.admin.monitor.votes_count", count: question.votes_count),
            answers: question.answers.map { |answer| answer_payload(answer) }
          }
        end

        def answer_payload(answer)
          {
            id: answer.id,
            votes_text: t("decidim.secure_elections.admin.monitor.votes_count", count: answer.votes_count.to_i),
            percent_text: number_to_percentage(answer.votes_percent, precision: 1)
          }
        end
      end
    end
  end
end
