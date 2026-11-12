# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Coalesces "a vote was cast" notifications from the booth into at most
      # one in-flight results-sync chain ({SyncResultsAfterVoteJob}) per
      # election, using three columns of the {Process} sidecar:
      #
      # * `live_sync_requests` — bumped by every accepted notification. The
      #   chain compares it with the value it saw on its previous check to
      #   tell whether more votes arrived meanwhile.
      # * `live_sync_until` — the chain's lease. A notification starts a chain
      #   only when no lease is held; otherwise the running chain picks the
      #   bump up on its next check and restarts its backoff.
      # * `synced_vote_count` — total `voteCount` at the last results sync, so
      #   the chain can tell when the tally moved.
      #
      # Claim and release are single conditional UPDATEs, so concurrent
      # notifications and the chain's own release cannot both miss each other.
      module LiveResultsSync
        # Added to every lease on top of the chain's next wait, so queue
        # latency or an ActiveJob retry does not let a second chain start
        # while this one is still due. If the chain dies the lease lapses and
        # the next notification starts a fresh one.
        LEASE_GRACE_S = 60

        module_function

        # Live sync only makes sense for a published `real_time` election.
        # The column check keeps a host app that has not run this gem's
        # migration working, minus the vote-driven sync.
        def applies_to?(election)
          process = election.vocdoni_process
          return false if process.blank? || process.vocdoni_process_id.blank? || !process.published?
          return false unless Decidim::Elections::Vocdoni::Process.column_names.include?("live_sync_until")

          election.results_availability.to_s == "real_time"
        end

        # Counts the notification and starts a chain unless one is in flight.
        # Returns true when it started one.
        def request!(process)
          now = Time.current
          scope = rows(process)
          scope.update_all("live_sync_requests = live_sync_requests + 1") # rubocop:disable Rails/SkipsModelValidations
          claimed = scope.where("live_sync_until IS NULL OR live_sync_until < ?", now)
                         .update_all(live_sync_until: now + LEASE_GRACE_S.seconds) # rubocop:disable Rails/SkipsModelValidations
          return false if claimed.zero?

          SyncResultsAfterVoteJob.perform_later(process.decidim_election_id, seen: requests(process))
          true
        end

        def requests(process)
          rows(process).pick(:live_sync_requests).to_i
        end

        # Extends the lease to cover a check `wait` seconds from now.
        def hold!(process, wait)
          rows(process).update_all(live_sync_until: Time.current + (wait + LEASE_GRACE_S).seconds) # rubocop:disable Rails/SkipsModelValidations
        end

        # Ends the chain unless a notification arrived after the chain read
        # `requests`; returns false in that case so the chain keeps going.
        def release!(process, requests:)
          rows(process).where(live_sync_requests: ..requests)
                       .update_all(live_sync_until: nil) == 1 # rubocop:disable Rails/SkipsModelValidations
        end

        # `Process` alone would resolve to Ruby's core module here.
        def rows(process)
          Decidim::Elections::Vocdoni::Process.where(id: process.id)
        end
      end
    end
  end
end
