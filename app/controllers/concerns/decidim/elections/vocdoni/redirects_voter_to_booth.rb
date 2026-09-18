# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Prepended onto upstream's `Decidim::Elections::VotesController` (see
      # `engine.rb` — the `extend_upstream` initializer).
      #
      # For a Vocdoni-backed election the whole voting flow lives in the
      # Vocdoni booth SPA (`/vocdoni/vote.html`), not in Decidim's own
      # per-question ballot pages. Upstream's votes controller would happily
      # walk the user through `#new` → `#show` → `#confirm` → `#cast`, which
      # for us is wrong: no Decidim vote record ever gets cast for a
      # Vocdoni election, and letting the wizard render would let a voter
      # ballot silently through the wrong path.
      #
      # Every action gets rewritten to render the standalone booth page —
      # except the receipt action, which is what the SPA sends the voter
      # back to on `exit`. Receipt-time skip keeps upstream's own receipt
      # rendering intact so the browser back-nav from the booth works.
      module RedirectsVoterToBooth
        extend ActiveSupport::Concern

        included do
          before_action :render_vocdoni_booth_if_backed
        end

        private

        def render_vocdoni_booth_if_backed
          return unless election.vocdoni_process.present?
          return if action_name == "receipt"

          render template: "decidim/elections/vocdoni/booth/show",
                 layout: "decidim/election_booth",
                 locals: { election: election }
        end
      end
    end
  end
end
