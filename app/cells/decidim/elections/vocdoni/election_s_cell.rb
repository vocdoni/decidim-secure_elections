# frozen_string_literal: true

require "cell/partial"

module Decidim
  module Elections
    module Vocdoni
    # The search (:s) card for an election.
    class ElectionSCell < Decidim::CardSCell
      private

      def metadata_cell
        "decidim/elections/vocdoni/election_card_metadata"
      end
    end
  end
end
end
