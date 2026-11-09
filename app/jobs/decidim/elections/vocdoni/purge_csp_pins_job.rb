# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Clears voter addresses and nullifiers from the CSP pin table 30 days
      # after results are published, keeping the row count and confirmation
      # state for auditing while reducing the amount of voter-linkable data
      # retained after the election closes.
      #
      # Enqueued by {SyncElectionResultsJob} the first time all questions report
      # final results, with a 30-day delay. The trigger allows setting address
      # and nullifier to NULL; changing them to any other value is rejected.
      class PurgeCspPinsJob < ApplicationJob
        queue_as :vocdoni

        def perform(process_id)
          process = Process.find_by(id: process_id)
          return if process.nil?

          count = CspPin.where(process:).where.not(address: nil).update_all( # rubocop:disable Rails/SkipsModelValidations
            address: nil,
            nullifier: nil,
            purged_at: Time.current
          )

          Rails.logger.info "[vocdoni] purged #{count} csp pin(s) for process #{process.id}"
        end
      end
    end
  end
end
