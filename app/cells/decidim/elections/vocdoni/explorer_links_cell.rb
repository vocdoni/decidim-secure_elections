# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Panel of the "Vocdoni explorer" tab on the public election page
      # (see {ExplorerTabPanel}). The model is the election.
      class ExplorerLinksCell < Decidim::ViewModel
        def show
          return if links.empty?

          render :show
        end

        private

        def links
          @links ||= ExplorerLinks.for(model)
        end
      end
    end
  end
end
