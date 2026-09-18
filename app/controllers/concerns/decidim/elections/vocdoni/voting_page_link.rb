# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    # Makes the voting page link available to the public engine and its views.
    #
    # The URL itself is built by `Decidim::Elections::Vocdoni::VotingPageUrl`, which is
    # also what the admin panel uses: the link an organiser copies and the link
    # the Vote button follows have to be the same link, so there is one place
    # that knows how to write it.
    #
    # What this concern adds is the one thing only a public request knows: where
    # "back to the election" goes. A voter who reached the page from the
    # election page has somewhere to return to; one who arrived from an email
    # does not, which is why the admin panel's copy of the link carries no exit.
    module VotingPageLink
      extend ActiveSupport::Concern

      included do
        helper_method :voting_page_url
      end

      private

      # The voting page link for an election, or nil when there is nothing to
      # link to — see `VotingPageUrl.build`.
      def voting_page_url(target = election)
        Decidim::Elections::Vocdoni::VotingPageUrl.build(target, locale: I18n.locale, exit_path: election_path(target))
      end
    end
  end
end
end
