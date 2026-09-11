# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    # Helpers shared by the public side of the component.
    module ApplicationHelper
      include Decidim::PaginateHelper

      # The label used for this component in page titles and headings.
      #
      # Administrators may rename the component per participatory space, so the
      # configured name wins; the manifest name is the fallback. Decidim's
      # shared pagination title partial expects a `component_name` helper to
      # exist, which is why this is not simply inlined in the view.
      def component_name
        (defined?(current_component) && translated_attribute(current_component&.name).presence) ||
          t("decidim.components.vocdoni.name")
      end
    end
  end
end
end
