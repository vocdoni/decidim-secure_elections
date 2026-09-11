# frozen_string_literal: true

require "cell/partial"

module Decidim
  module Elections
    module Vocdoni
    # The list (:l) card for an election.
    class ElectionLCell < Decidim::CardLCell
      private

      def has_description?
        true
      end

      def metadata_cell
        "decidim/elections/vocdoni/election_card_metadata"
      end
    end
  end
end
end
