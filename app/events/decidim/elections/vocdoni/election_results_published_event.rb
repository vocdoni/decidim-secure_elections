# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    # Notifies followers that an election has closed and its tally is available.
    #
    # Publish it once the results are final — that is, once
    # `Decidim::Elections::Vocdoni::SyncResultsJob` has stored a tally whose questions are
    # all flagged `final` — with:
    #
    #   Decidim::EventsManager.publish(
    #     event: "decidim.events.elections.vocdoni.election_results_published",
    #     event_class: Decidim::Elections::Vocdoni::ElectionResultsPublishedEvent,
    #     resource: election,
    #     followers: election.followers | election.participatory_space.followers
    #   )
    #
    # It deliberately carries no figures: results are read from the chain and
    # can still be refreshed, so the notification links to the election page
    # rather than restating a number that may already be stale.
    class ElectionResultsPublishedEvent < Decidim::Events::SimpleEvent
      def button_text
        I18n.t("button_text", scope: "decidim.events.elections.vocdoni.election_results_published")
      end

      def button_url
        resource_url
      end
    end
  end
end
end
