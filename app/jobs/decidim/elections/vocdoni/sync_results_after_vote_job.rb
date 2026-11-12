# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Live results for a `real_time` election, driven by votes rather than a
      # fast timer. Started by {LiveResultsSync.request!} when the booth
      # reports a cast; at most one chain runs per election.
      #
      # Each check pulls `GET /processes/{id}/results` exactly like
      # {SyncElectionResultsJob} (same write path) and then:
      #
      # * more votes were reported since the previous check → restart the
      #   backoff, so a burst of voters keeps one chain on its shortest wait;
      # * otherwise, the tally grew past the last synced total, or the
      #   backoff ran out → release the lease and stop;
      # * otherwise → wait the next `POLL_BACKOFF_S` step and check again.
      #
      # The first check runs right away (a cast is confirmed in a block
      # before the booth reports it), then 5, 10, 15, 30, 60 s apart: about
      # 2 min before giving up on a vote the tally never showed. The slow
      # fallback poll in {SyncProcessJob} covers anything missed.
      class SyncResultsAfterVoteJob < SyncElectionResultsJob
        # `seen` is `live_sync_requests` as read at the previous check (or
        # when the chain was claimed).
        def perform(election_id, seen:, attempt: 1)
          return unless bootstrap!(election_id)

          requests = LiveResultsSync.requests(process)
          previous = process.synced_vote_count
          sync_and_maybe_reschedule!(mode: :after_vote, attempt:)
          progressed = process.synced_vote_count.to_i > previous.to_i

          continue_or_stop!(requests:, seen:, attempt:, progressed:)
        rescue Decidim::Elections::Vocdoni::ApiError => e
          process&.record_failure!(redact(e.message), step: "sync_results", code: e.try(:code))
          raise if e.transient?
        end

        private

        def continue_or_stop!(requests:, seen:, attempt:, progressed:)
          more_votes = requests > seen
          done = !more_votes && (progressed || attempt > POLL_BACKOFF_S.size)
          return if done && LiveResultsSync.release!(process, requests:)

          # A vote reported after `requests` was read keeps a finished chain alive.
          step = more_votes || done ? 1 : attempt
          wait = self.class.poll_delay(step)
          LiveResultsSync.hold!(process, wait)
          self.class.set(wait: wait.seconds).perform_later(election.id, seen: requests, attempt: step + 1)
        end
      end
    end
  end
end
