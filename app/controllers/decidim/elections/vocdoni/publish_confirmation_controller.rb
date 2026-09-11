# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Renders the "you are about to write this election to the blockchain"
      # checklist that stands between the admin's click on Publish and
      # {Decidim::Elections::Admin::ElectionsController#publish}.
      #
      # Reached by the interceptor installed on `phase_4_spike` (see the
      # `to_prepare` block that prepends `PublishInterceptor` onto the upstream
      # controller): a PUT `/elections/:id/publish` on a vocdoni_secure
      # election without `confirmed=1` in the URL is redirected here first;
      # the "Yes, publish" button on this page re-issues the PUT with the
      # `confirmed=1` flag so the interceptor lets it through.
      class PublishConfirmationController < Decidim::Admin::ApplicationController
        include Decidim::Admin::Concerns::HasComponent
        helper_method :election

        def show
          enforce_permission_to(:read, :election, election:)
        end

        private

        def election
          @election ||= Decidim::Elections::Election
                        .where(component: current_component)
                        .find(params[:election_id])
        end
      end
    end
  end
end
