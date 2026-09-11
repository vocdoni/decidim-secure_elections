# frozen_string_literal: true

require "decidim/components/namer"

Decidim.register_component(:vocdoni) do |component|
  component.engine = Decidim::Elections::Vocdoni::Engine
  component.admin_engine = Decidim::Elections::Vocdoni::AdminEngine
  component.icon = "media/images/decidim_elections_vocdoni.svg"
  component.icon_key = "check-double-line"
  component.stylesheet = "decidim/elections/vocdoni/vocdoni"
  component.permissions_class_name = "Decidim::Elections::Vocdoni::Permissions"

  # GraphQL. Elections are public objects and belong in the API, so the
  # component exposes a query type rather than leaving them invisible to it.
  component.query_type = "Decidim::Elections::Vocdoni::VocdoniElectionsType"

  # Actions the permission system can authorize from the admin panel. `vote` is
  # gated by the Vocdoni census, but exposing it here lets admins additionally
  # require a Decidim verification before the voting page is even reachable.
  component.actions = %w(vote)

  component.on(:publish) do |instance|
    Decidim::Elections::Vocdoni::Election.where(component: instance).find_in_batches(batch_size: 100) do |batch|
      Decidim::UpdateSearchIndexesJob.perform_later(batch)
    end
  end

  component.on(:unpublish) do |instance|
    Decidim::Elections::Vocdoni::Election.where(component: instance).find_in_batches(batch_size: 100) do |batch|
      Decidim::RemoveSearchIndexesJob.perform_later(batch)
    end
  end

  component.settings(:global) do |settings|
    settings.attribute :announcement, type: :text, translated: true, editor: true
  end

  component.settings(:step) do |settings|
    settings.attribute :announcement, type: :text, translated: true, editor: true
  end

  component.register_stat :elections_count,
                          primary: true,
                          priority: Decidim::StatsRegistry::HIGH_PRIORITY,
                          icon_name: "check-double-line",
                          tooltip_key: "elections_count_tooltip" do |components, _start_at, _end_at|
    Decidim::Elections::Vocdoni::Election.where(component: components).published.count
  end

  component.register_stat :votes_count,
                          priority: Decidim::StatsRegistry::MEDIUM_PRIORITY,
                          icon_name: "check-line",
                          tooltip_key: "votes_count_tooltip" do |components, _start_at, _end_at|
    Decidim::Elections::Vocdoni::Election.where(component: components).published.sum(:votes_count)
  end

  component.register_resource(:election) do |resource|
    resource.model_class_name = "Decidim::Elections::Vocdoni::Election"
    resource.card = "decidim/elections/vocdoni/election"
    resource.searchable = true
    # What the resource-permissions screen offers per election. Without it an
    # admin can only require a Decidim verification for the whole component,
    # never for one election — which is the finer grain the component's own
    # `actions` above exist to allow.
    resource.actions = %w(vote)
  end

  # Results export. Missing from decidim-elections entirely; admins running a
  # real election need the tally in a portable format.
  component.exports :election_results do |exports|
    exports.collection do |component_instance|
      Decidim::Elections::Vocdoni::Election.where(component: component_instance).published
    end
    exports.include_in_open_data = true
    exports.serializer Decidim::Elections::Vocdoni::ElectionResultsSerializer
  end

  component.seeds do |participatory_space|
    require "decidim/elections/vocdoni/seeds"

    Decidim::Elections::Vocdoni::Seeds.new(participatory_space:).call
  end
end
