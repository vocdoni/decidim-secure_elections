# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # What the redesigned Census tab needs on top of upstream's controller:
      # the page's data ({CensusTabData}, shared with the controller behind the
      # "Your list" card) plus the one guard that belongs to saving it.
      module CensusPage
        extend ActiveSupport::Concern
        include CensusTabData

        included do
          # Upstream's `update` reads `election.census.admin_form` with no
          # guard, so a save that names no census type raises. The old page
          # could not produce one (its Save button was hidden until a type was
          # picked); the new one keeps the button reachable, so the case is
          # answered here instead.
          #
          # It is on this concern rather than the shared one because the
          # controller behind the card legitimately runs before any type has
          # been saved: choosing a file is how the type gets chosen.
          #
          # `update` is upstream's action, on the controller this is included
          # onto, and the cop cannot see it from here.
          before_action :ensure_census_type_chosen, only: :update # rubocop:disable Rails/LexicallyScopedActionFilter
        end

        private

        def ensure_census_type_chosen
          return if election.census.present?

          flash[:alert] = I18n.t("census_setup.no_choice", scope: "decidim.elections.vocdoni.admin")
          # The tab is a member route on the election (`get "census"`), not the
          # `edit` of the singular resource that also answers this PATCH.
          redirect_to Decidim::EngineRouter.admin_proxy(current_component).census_election_path(election)
        end
      end
    end
  end
end
