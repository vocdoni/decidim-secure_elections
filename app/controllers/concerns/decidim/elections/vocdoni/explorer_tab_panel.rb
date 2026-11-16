# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Prepended to upstream's public `Decidim::Elections::ElectionsController`
      # (see engine.rb `explorer_tab`): appends the "Vocdoni explorer" tab to
      # the attachment tabs the election page renders. The tab only shows once
      # the election is on chain.
      module ExplorerTabPanel
        private

        # Its own ivar: upstream memoizes `@tab_panel_items` inside `super`.
        def tab_panel_items
          @vocdoni_tab_panel_items ||= super + [
            {
              enabled: ExplorerLinks.for(election).any?,
              id: "vocdoni-explorer",
              text: I18n.t("decidim.elections.vocdoni.explorer.tab"),
              icon: "external-link-line",
              method: :cell,
              args: ["decidim/elections/vocdoni/explorer_links", election]
            }
          ]
        end
      end
    end
  end
end
