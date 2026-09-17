# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Queues a census pre-flight for an election that opted in to Vocdoni.
      #
      # Called whenever something the pre-flight depends on changes: the
      # census (upstream Census tab save, CSV import or removal) or the
      # Security tab (identifiers, one-time code). The roster or the
      # identifiers may have changed, so the Vocdoni group built by a previous
      # run no longer matches and is dropped; the job builds a new one.
      #
      # The validation is marked pending synchronously, so the page the admin
      # lands on never shows the result of the previous state.
      #
      # No-op for elections that have not opted in, that are already on chain,
      # or whose census is not ready yet (nothing to check).
      class PreflightTrigger
        def self.call(election)
          new(election).call
        end

        def initialize(election)
          @election = election
        end

        def call
          process = election.vocdoni_process
          return false if process.blank? || process.published? || process.vocdoni_process_id.present?

          process.census_group_id = nil
          unless election.census_ready?
            process.invalidate_census_validation!
            process.save! if process.changed?
            return false
          end

          process.mark_census_validation_pending!
          PreflightCensusJob.perform_later(election.id)
          true
        end

        private

        attr_reader :election
      end
    end
  end
end
