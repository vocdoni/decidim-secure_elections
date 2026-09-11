# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Admin
        # Runs after upstream's `ProcessCensus` command has persisted
        # `election.census_manifest = "vocdoni_secure"` and
        # `election.census_settings = form.census_settings` — that is, after
        # the admin saves the Census tab for a Vocdoni-backed election.
        #
        # Registered via `manifest.after_update_command = ...` in the engine.
        #
        # Its only job in Stage A: make sure a `Vocdoni::Process` sidecar row
        # exists for the election in the `pending` state, so downstream code
        # (publish subscriber, dashboard, monitor) can find it. It is
        # idempotent — re-saving the census tab does not reset the state.
        class AfterUpdateCensus
          def self.call(form, election)
            return unless form.valid?

            process = Vocdoni::Process.find_or_initialize_by(decidim_election_id: election.id)
            process.state ||= "pending"
            process.save!
            process
          end
        end
      end
    end
  end
end
