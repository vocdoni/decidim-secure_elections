# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Abstract controller all admin controllers of this engine inherit from.
      #
      # Nothing here — or in any subclass — is allowed to call the Vocdoni API.
      # Every upstream interaction goes through an ActiveJob
      # (`Decidim::Elections::Vocdoni::ApplicationJob` and friends), so that a slow or
      # unreachable SaaS never turns into a hanging request or a timeout in the
      # admin panel (ARCHITECTURE §0.5).
      class ApplicationController < Decidim::Admin::Components::BaseController
        # The wizard is a sequence again, and a strict one. Every screen that
        # belongs to a step declares it with `wizard_step`; a request for a step
        # whose prerequisites do not hold is redirected rather than rendered.
        include Decidim::Elections::Vocdoni::Admin::WizardStep

        helper Decidim::ApplicationHelper
        helper Decidim::Elections::Vocdoni::Admin::ElectionsHelper

        helper_method :election, :module_configured?

        private

        # Answers an autosave that the permission chain refused.
        #
        # `enforce_permission_to` raises, and Decidim turns that into an HTML
        # redirect. That is the right answer for a page request and the wrong
        # one here: the editor's poller asked for JSON, so it would get HTML
        # where it expects a body, fall into its catch-all and report the
        # generic "could not be saved" — for a condition that will never clear.
        #
        # The realistic way to hit this is a race rather than mischief: an
        # admin leaves the ballot open while the publish job lands, and every
        # keystroke after that is being autosaved against an election that is
        # now on chain and immutable.
        #
        # `refused` is what tells the browser to stop trying. An ordinary
        # validation failure is also 422, but that one is worth retrying and
        # this one never will be.
        def autosave_refused
          # i18n-tasks-use t("decidim.elections.vocdoni.admin.autosave.on_chain")
          # i18n-tasks-use t("decidim.elections.vocdoni.admin.autosave.locked")
          key = election.on_chain? ? :on_chain : :locked

          render json: {
            saved: false,
            refused: true,
            errors: [t(key, scope: "decidim.elections.vocdoni.admin.autosave")]
          }, status: :unprocessable_content
        end

        def elections
          @elections ||= Decidim::Elections::Vocdoni::Election.where(component: current_component)
        end

        def election
          @election ||= elections.find(params.expect(:election_id))
        end

        # Purely a local read of the module settings. It never reveals the
        # values themselves, only whether they are present (ARCHITECTURE §0.2).
        def module_configured?
          Decidim::Elections::Vocdoni.configured?
        end
      end
    end
  end
end
end
