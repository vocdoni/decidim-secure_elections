# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Admin
        # Security tab. Owns two concerns:
        #
        #   1. The Vocdoni opt-in ({AdminForms::SecurityForm#enable_vocdoni}).
        #      Opting in creates the {Vocdoni::Process} sidecar whose presence
        #      is the signal the publish subscriber uses to enqueue
        #      {PublishElectionJob}.
        #
        #   2. Two operator-triggered maintenance actions for external-CSP
        #      elections: `sync_census_size` and `verify_roots`. Both only
        #      enqueue background jobs (gem ARCHITECTURE §0.5). The external
        #      CSP pilot authenticates voters via Decidim itself; the
        #      second-factor field is locked and stored as `[]` until OTP is
        #      wired up in a later release.
        #
        # Inherits from upstream's `Decidim::Elections::Admin::ApplicationController`
        # rather than the Vocdoni admin base, because the elections component
        # uses upstream's admin engine and its controllers work off
        # `Decidim::Elections::Election`, not the Vocdoni-only Election model.
        class SecurityController < ::Decidim::Elections::Admin::ApplicationController
          helper_method :election

          def show
            enforce_permission_to(:update, :census, election:)

            @form = security_form
          end

          def update
            enforce_permission_to(:update, :census, election:)

            @form = form(AdminForms::SecurityForm).from_params(params)
            # Captured before the Decidim::Command call because on(:ok)/on(:invalid)
            # run with `instance_eval` inside the command: `self` there is the
            # command, not the controller, so route helpers would raise
            # NoMethodError. On success continue the wizard onto Dashboard,
            # matching the "Save and continue" label on Questions and Census.
            next_path = Decidim::EngineRouter.admin_proxy(election.component)
                                             .dashboard_election_path(election)

            UpdateElectionSecurity.call(@form, election) do
              on(:ok) do
                flash[:notice] = I18n.t("security.update.success", scope: "decidim.elections.vocdoni.admin")
                redirect_to next_path
              end

              on(:invalid) do
                flash.now[:alert] = I18n.t("security.update.invalid", scope: "decidim.elections.vocdoni.admin")
                render action: "show", status: :unprocessable_content
              end
            end
          end

          # Enqueues a census resize for the process. Only enqueues; never calls
          # the API directly (gem ARCHITECTURE §0.5).
          def sync_census_size
            enforce_permission_to(:dashboard, :election, election:)
            dashboard_path = Decidim::EngineRouter.admin_proxy(election.component)
                                                  .dashboard_election_path(election)

            process = election.vocdoni_process
            if process&.id
              ResizeCensusJob.perform_later(process.id)
              flash[:notice] = I18n.t("security.sync_census_size.success", scope: "decidim.elections.vocdoni.admin")
            else
              flash[:alert] = I18n.t("security.sync_census_size.not_available", scope: "decidim.elections.vocdoni.admin")
            end

            redirect_to dashboard_path
          end

          # Enqueues a SyncProcessJob, which runs verify_roots! when the process
          # is published and csp_state is nil. Only enqueues; never calls the API
          # directly (gem ARCHITECTURE §0.5).
          def verify_roots
            enforce_permission_to(:dashboard, :election, election:)
            dashboard_path = Decidim::EngineRouter.admin_proxy(election.component)
                                                  .dashboard_election_path(election)

            SyncProcessJob.perform_later(election.id)
            flash[:notice] = I18n.t("security.verify_roots.success", scope: "decidim.elections.vocdoni.admin")
            redirect_to dashboard_path
          end

          private

          def election
            @election ||= ::Decidim::Elections::Election.where(component: current_component).find(params.expect(:election_id))
          end

          def security_form
            AdminForms::SecurityForm.from_model(election)
          end
        end
      end
    end
  end
end
