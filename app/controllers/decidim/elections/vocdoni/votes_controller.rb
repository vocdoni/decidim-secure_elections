# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    # The old voting routes, kept as redirects.
    #
    # Voting used to be three Rails views rendered by this controller. It is now
    # a static page shipped inside the gem and served by the engine's own
    # middleware — see `Decidim::Elections::Vocdoni::VotingPageLink`. Nothing about a
    # ballot ever reached this controller even then; now nothing at all does.
    #
    # These actions survive only so that links minted before the change — a
    # bookmark, an email, a printed QR code — still land the voter on a ballot:
    #
    #   GET …/vote/new      ┐
    #   GET …/vote          ├─ /vocdoni/vote.html?v=…
    #   GET …/vote/receipt  ┘
    #
    # All three collapse into one destination because the static page has a
    # single entry point: the voter identifies themselves, and is then shown a
    # ballot or the receipts for a vote they have already cast, whichever is
    # true. There is nothing left for a separate receipt route to select.
    class VotesController < Decidim::Elections::Vocdoni::ApplicationController
      def new
        redirect_to_voting_page
      end

      def show
        redirect_to_voting_page
      end

      def receipt
        redirect_to_voting_page
      end

      private

      # `:found`, not `:moved_permanently`, on purpose: the target carries the
      # participant's locale, so a permanently cached redirect would pin every
      # later visit to whichever language they happened to use first.
      def redirect_to_voting_page
        target = voting_page_url

        if target.blank?
          redirect_to exit_path, alert: t("decidim.elections.vocdoni.votes.errors.not_on_chain")
        else
          redirect_to target, status: :found
        end
      end
    end
  end
end
end
