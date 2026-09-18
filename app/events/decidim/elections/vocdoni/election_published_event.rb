# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    # Notifies the followers of a participatory space that an election is open
    # for voting.
    #
    # Publish it with:
    #
    #   Decidim::EventsManager.publish(
    #     event: "decidim.events.elections.vocdoni.election_published",
    #     event_class: Decidim::Elections::Vocdoni::ElectionPublishedEvent,
    #     resource: election,
    #     followers: election.participatory_space.followers
    #   )
    #
    # The event name doubles as the i18n scope (see
    # `Decidim::Events::SimpleEvent#i18n_scope`), so it must stay in sync with
    # `decidim.events.elections.vocdoni.election_published` in `config/locales/en.yml`.
    class ElectionPublishedEvent < Decidim::Events::SimpleEvent
      def resource_text
        translated_attribute(resource.description)
      end

      def button_text
        I18n.t("button_text", scope: "decidim.events.elections.vocdoni.election_published")
      end

      def button_url
        resource_url
      end
    end
  end
end
end
