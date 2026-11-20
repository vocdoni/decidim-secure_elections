# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # The SaaS organization takes one transaction at a time, so a busy answer
      # (`ApiError#busy?`) is a wait: the job reschedules itself for up to
      # `BUSY_WINDOW_S`, leaving the process state, `last_error` and `retry_on` alone.
      module BusyRetry
        extend ActiveSupport::Concern

        BUSY_DELAYS_S = [2, 4, 8].freeze
        BUSY_CADENCE_S = 15
        BUSY_JITTER = 0.2
        BUSY_WINDOW_S = 15 * 60

        class_methods do
          # Seconds before the run after busy answer number `attempt` (1-based),
          # ±20 % so concurrent jobs spread out, never below `retry_after` or 1 s.
          def busy_delay(attempt, retry_after: nil)
            base = BUSY_DELAYS_S.fetch(attempt - 1, BUSY_CADENCE_S)
            [base * rand((1 - BUSY_JITTER)..(1 + BUSY_JITTER)), retry_after.to_i, 1].max
          end
        end

        protected

        # Records a busy answer for the action under `key` and, inside the window
        # (from `busy_since`, the first busy answer), yields the delay and next
        # run's arguments to reschedule. Returns nil (not busy), :waiting or :gave_up.
        def wait_out_busy(error, key, busy_since:, busy_attempts:, sticky_give_up: true)
          return nil unless error.respond_to?(:busy?) && error.busy?

          entry = process.pending_actions[key]
          # A fresh run of a given-up action stays given up: {SyncProcessJob} retries it.
          if busy_since.blank? && sticky_give_up && entry.to_h["gave_up"]
            process.record_pending_action!(key, since: entry["since"], attempts: entry["attempts"].to_i + 1, gave_up: true)
            Rails.logger.warn "[vocdoni] #{key} of election ##{election.id}: the organization is still busy; left to the sync"
            return :gave_up
          end

          since = busy_since.presence || Time.current.iso8601
          attempts = busy_attempts.to_i + 1
          if Time.current - (Decidim::Elections::Vocdoni::Process.parse_time(since) || Time.current) >= BUSY_WINDOW_S
            process.record_pending_action!(key, since:, attempts:, gave_up: true)
            Rails.logger.error "[vocdoni] #{key} of election ##{election.id}: the organization stayed busy " \
                               "for #{BUSY_WINDOW_S / 60} minutes (#{attempts} attempts); giving up"
            return :gave_up
          end

          delay = self.class.busy_delay(attempts, retry_after: error.retry_after)
          # `next_in` keeps the entry live through a long Retry-After for the reconciler.
          process.record_pending_action!(key, since:, attempts:, next_in: delay)
          Rails.logger.warn "[vocdoni] #{key} of election ##{election.id}: the organization is busy " \
                            "(attempt #{attempts}); retrying in #{delay.round(1)}s"
          yield delay, { busy_since: since, busy_attempts: attempts }
          :waiting
        end

        # Any other answer ends the wait and the job's own error handling takes
        # over; a given-up entry stays for {SyncProcessJob} to retry.
        def end_busy_wait(key)
          process.clear_pending_action!(key) unless process.pending_actions.dig(key, "gave_up")
        end
      end
    end
  end
end
