# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Admin
        # The Dashboard's "Retry publication" button. Re-enqueues
        # {PublishElectionJob} for an election whose last publish failed; the
        # job skips every step already done upstream (members, census,
        # process), so a refused payment retries only the publish.
        #
        # Inherits from upstream's admin controller for the same reason as
        # {SecurityController}.
        class PublishRetriesController < ::Decidim::Elections::Admin::ApplicationController
          def create
            # A write permission, since a retry spends integrator credit. Not
            # :publish nor :update :census: upstream denies both once the
            # election is published in Decidim, exactly when a push has failed.
            enforce_permission_to(:update, :election, election:)

            process = election.vocdoni_process
            if process&.failed?
              Decidim::Elections::Vocdoni::PublishElectionJob.perform_later(election.id)
              flash[:notice] = I18n.t("create.success", scope: "decidim.elections.vocdoni.admin.publish_retries")
            else
              flash[:alert] = I18n.t("create.not_failed", scope: "decidim.elections.vocdoni.admin.publish_retries")
            end

            redirect_to Decidim::EngineRouter.admin_proxy(election.component).dashboard_election_path(election)
          end

          private

          def election
            @election ||= ::Decidim::Elections::Election.where(component: current_component).find(params.expect(:election_id))
          end
        end
      end
    end
  end
end
