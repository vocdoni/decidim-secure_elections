# frozen_string_literal: true

# Phase-4 spike: proves the extension surface added to upstream
# decidim-elections (vocdoni/decidim#1, #2, integrated on
# `phase-4/integration`) is enough to plug the Vocdoni backend in as an
# optional "security layer" without patching any upstream file.
#
# Loaded only when the environment variable `PHASE_4_SPIKE=1` is set, so
# the existing `Decidim::Elections::Vocdoni` production code path is
# unaffected.
#
# Success criteria (verify in the Decidim admin):
#   - The census-manifest combobox for a new election lists "Secure via
#     Vocdoni (spike)".
#   - The results-availability select on the election form lists
#     "Blockchain-backed (spike)".
#   - Publishing the election writes a line to the Rails log:
#     "[phase-4-spike] publish_election:after fired for election #<id>".
#
# All three come out of upstream-hook subscriptions — no upstream file
# is patched at runtime.

require "decidim/elections"

module Decidim
  module Elections
    module Vocdoni
    module Phase4Spike
      class Engine < ::Rails::Engine
        engine_name "decidim_elections_vocdoni_phase_4_spike"

        # Views + locales live under the spike's own path so nothing collides
        # with the main engine.
        paths["app/views"] = "lib/decidim/elections/vocdoni/phase_4_spike/views"
        paths["config/locales"] = "lib/decidim/elections/vocdoni/phase_4_spike/config/locales"

        initializer "phase_4_spike.register_census_manifest" do
          Decidim::Elections.census_registry.register(:vocdoni_secure) do |manifest|
            manifest.admin_form = "Decidim::Elections::Vocdoni::AdminForms::CensusForm"
            manifest.admin_form_partial = "decidim/elections/vocdoni/admin/censuses/vocdoni_secure_form"
            manifest.after_update_command = "Decidim::Elections::Vocdoni::Admin::AfterUpdateCensus"
            manifest.voter_form = "Decidim::Elections::Vocdoni::VoterForms::PassthroughForm"
            manifest.voter_form_partial = "decidim/elections/vocdoni/booth/launcher"
            manifest.user_query do |election|
              # Stage A/B: the census is every registered user of the org,
              # capped at 20 for the spike so publish + memberbase upload
              # finish quickly against the stg SaaS. When we grow into real
              # deployments this cap goes away and the roster is picked
              # explicitly from the admin form.
              Decidim::User
                .where(organization: election.organization)
                .where.not(email: nil)
                .order(id: :asc)
                .limit(20)
            end
          end
        end

        # Decorate upstream `Decidim::Elections::Election` with `has_one
        # :vocdoni_process`, so `election.vocdoni_process` reads naturally
        # everywhere. Runs on every code reload in development (`to_prepare`)
        # and once in production, after Zeitwerk has loaded the upstream
        # model. Idempotent — Rails allows `has_one` redeclaration.
        initializer "phase_4_spike.extend_election_model" do |app|
          app.config.to_prepare do
            Decidim::Elections::Election.has_one :vocdoni_process,
                                                 class_name: "Decidim::Elections::Vocdoni::Process",
                                                 foreign_key: "decidim_election_id",
                                                 dependent: :destroy,
                                                 inverse_of: :election
          end
        end

        initializer "phase_4_spike.register_results_availability" do
          Decidim::Elections.register_results_availability(:blockchain_backed)
        end

        # Enqueues {PublishToVocdoniJob} whenever a Vocdoni-backed election is
        # published from the Decidim admin. The subscription piggybacks on the
        # `decidim.elections.admin.publish_election:after` notification added
        # by vocdoni/decidim#2 (see phase-4/integration).
        #
        # The subscriber runs on the request thread but is intentionally cheap:
        # the actual work happens in the Sidekiq job. Filters out elections
        # that are not Vocdoni-backed so a plain-CSV election published in the
        # same host does not enqueue anything.
        # `Decidim::Command#with_events` publishes via
        # `ActiveSupport::Notifications.publish(name, **event_arguments)`, not
        # `.instrument`. Subscribers therefore receive a 2-arg block —
        # `|event_name, data|` — where `data` is the kwargs hash, not the
        # standard 5-arg `|name, started, finished, id, payload|` shape that
        # `instrument` uses. Getting this wrong raises `nil[:election]` on
        # every publish.
        initializer "phase_4_spike.subscribe_to_publish" do
          ActiveSupport::Notifications.subscribe("decidim.elections.admin.publish_election:after") do |_event_name, data|
            election = data[:election]
            next if election.blank?

            Rails.logger.info "[phase-4-spike] publish_election:after fired for election ##{election.id} (manifest=#{election.census_manifest.inspect})"

            if election.census_manifest.to_s == "vocdoni_secure"
              Decidim::Elections::Vocdoni::PublishToVocdoniJob.perform_later(election.id)
              Rails.logger.info "[phase-4-spike] enqueued PublishToVocdoniJob for election ##{election.id}"
            end
          end
        end
      end
    end
  end
end
end
