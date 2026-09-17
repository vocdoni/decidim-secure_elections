# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Admin
        # Prepended onto upstream's `Decidim::Elections::Admin::ProcessCensus`
        # (see `phase_4_spike.rb`), which runs when the admin saves the Census
        # tab.
        #
        # - A file census whose type was just changed to something else leaves
        #   its rows behind upstream; they are removed so they cannot resurface.
        # - An election that opted in to Vocdoni gets a fresh census pre-flight.
        module CensusSavedHook
          def run_after_hooks
            super
            election = resource
            election.voters.delete_all if election.census_manifest.to_s != "token_csv" && election.voters.exists?
            PreflightTrigger.call(election)
          end
        end
      end
    end
  end
end
