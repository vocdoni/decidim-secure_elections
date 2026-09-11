# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Prepended onto {Decidim::Elections::Admin::ElectionsController} by the
      # phase_4_spike engine. Intercepts the publish action for Vocdoni-backed
      # elections and bounces the admin to the confirmation page unless the
      # URL carries `confirmed=1`.
      #
      # Rationale: writing an election to the blockchain is irreversible, so
      # the click that does it cannot be one dropdown-menu item away from
      # everything else. The confirmation page carries the checklist and the
      # irreversibility warning; only when the admin has read it and clicked
      # "Yes, publish" does the actual PUT reach the upstream controller.
      module PublishInterceptor
        def publish
          if requires_confirmation?
            redirect_to Decidim::EngineRouter.admin_proxy(current_component)
                          .confirm_publish_election_path(election)
            return
          end

          super
        end

        private

        def requires_confirmation?
          return false unless election
          return false unless election.census_manifest.to_s == "vocdoni_secure"

          params[:confirmed].to_s != "1"
        end
      end
    end
  end
end
