# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    # Entry point for `resource.card = "decidim/elections/vocdoni/election"`: dispatches to
    # the card size Decidim asked for.
    class ElectionCell < Decidim::ViewModel
      include Cell::ViewModel::Partial

      def show
        cell card_size, model, options
      end

      private

      def card_size
        case options[:size]
        when :s
          "decidim/elections/vocdoni/election_s"
        when :g
          "decidim/elections/vocdoni/election_g"
        else
          "decidim/elections/vocdoni/election_l"
        end
      end
    end
  end
end
end
