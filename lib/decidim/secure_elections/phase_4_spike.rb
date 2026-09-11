# frozen_string_literal: true

# Phase-4 spike: proves the extension surface added to upstream
# decidim-elections (vocdoni/decidim#1, #2, integrated on
# `phase-4/integration`) is enough to plug the Vocdoni backend in as an
# optional "security layer" without patching any upstream file.
#
# Loaded only when the environment variable `PHASE_4_SPIKE=1` is set, so
# the existing `Decidim::SecureElections` production code path is
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
  module SecureElections
    module Phase4Spike
      class Engine < ::Rails::Engine
        engine_name "decidim_secure_elections_phase_4_spike"

        # Views + locales live under the spike's own path so nothing collides
        # with the main SecureElections engine.
        paths["app/views"] = "lib/decidim/secure_elections/phase_4_spike/views"
        paths["config/locales"] = "lib/decidim/secure_elections/phase_4_spike/config/locales"

        initializer "phase_4_spike.register_census_manifest" do
          Decidim::Elections.census_registry.register(:vocdoni_secure) do |manifest|
            manifest.admin_form = "Decidim::SecureElections::Phase4Spike::AdminForm"
            manifest.admin_form_partial = "decidim/secure_elections/phase_4_spike/admin_form"
            manifest.user_query do |election|
              # Spike-only: the "census" is every user in the org.
              Decidim::User.where(organization: election.organization)
            end
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

      # Minimal Form so the census-manifest combobox has something to render
      # when the admin picks "Secure via Vocdoni (spike)". The real backend
      # would carry SaaS URL / API key / org address here.
      class AdminForm < Decidim::Form
        attribute :placeholder, String
      end
    end
  end
end
