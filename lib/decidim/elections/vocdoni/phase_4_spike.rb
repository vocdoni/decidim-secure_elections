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
            manifest.user_query do |election|
              # Stage A: the census is every user in the org. Stage B/C replaces
              # this with the actual roster (see admin_form for how the
              # identifier fields are picked).
              Decidim::User.where(organization: election.organization)
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

        initializer "phase_4_spike.subscribe_to_publish" do
          ActiveSupport::Notifications.subscribe("decidim.elections.admin.publish_election:after") do |_name, _started, _finished, _id, payload|
            election = payload[:election]
            Rails.logger.info "[phase-4-spike] publish_election:after fired for election ##{election&.id}"
          end
        end
      end
    end
  end
end
end
