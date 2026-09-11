# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    class ApiClient
      # Async jobs.
      #
      # Publishing a process, moving question status and relaying a vote all
      # answer `{"jobId": "…"}` and finish later. Poll with {#wait_for}.
      #
      # ⚠️ A job body carries a **nested `result.status`** — for a publish it
      # reads `"READY"`, the *election's* status — which is not the job status.
      # Only the top-level `status` (`pending` / `completed` / `failed`) says
      # whether the job is done. A completed publish looks like:
      #
      #   {"jobId":"…","type":"publish_voting_process","status":"completed",
      #    "result":{"status":"READY"}}
      class Jobs < Base
        # Top-level status of a job that succeeded.
        COMPLETED_STATUS = "completed"

        # Top-level statuses of a job that will never succeed. The API
        # documents `failed`; the others are accepted defensively so an
        # unexpected terminal state raises instead of polling until timeout.
        FAILED_STATUSES = %w(failed error canceled cancelled).freeze

        # Seconds between two polls.
        DEFAULT_INTERVAL = 1.5

        # Reads a job — `GET /jobs/{id}`.
        #
        # @param job_id [String]
        # @return [Hash] `{"jobId" => …, "type" => …, "status" => …,
        #   "result" => {...}, "errors" => [...]}`.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def get(job_id)
          client.get("/jobs/#{job_id}")
        end

        # Polls `GET /jobs/{id}` until the job reaches a terminal state.
        #
        # The job is always read at least once, so `timeout: 0` performs a
        # single check. Only the **top-level** `status` is considered.
        #
        # @param job_id [String]
        # @param timeout [Numeric] seconds to wait before giving up. Defaults
        #   to `Decidim::Elections::Vocdoni.job_timeout`.
        # @param interval [Numeric] seconds between two polls.
        # @return [Hash] the completed job.
        # @raise [Decidim::Elections::Vocdoni::JobError] when the job fails or the timeout
        #   elapses.
        # @raise [Decidim::Elections::Vocdoni::ApiError] when a poll itself fails.
        #
        # @example Publishing and waiting for the chain
        #   job = client.jobs.wait_for(client.elections.publish(process_id)["jobId"])
        #   job["result"]["status"] # => "READY"
        def wait_for(job_id, timeout: nil, interval: DEFAULT_INTERVAL)
          timeout ||= Decidim::Elections::Vocdoni.job_timeout
          deadline = monotonic_time + timeout.to_f

          loop do
            job = get(job_id)
            status = job["status"].to_s.downcase

            return job if status == COMPLETED_STATUS
            # A job that reports a terminal failure status is an *answer*, not a
            # network flap: retrying it would poll the same failed record and
            # fail identically.
            raise Decidim::Elections::Vocdoni::JobError.new(failure_message(job_id, job), body: job, transient: false) if FAILED_STATUSES.include?(status)

            if monotonic_time >= deadline
              raise Decidim::Elections::Vocdoni::JobError.new(
                "Timed out after #{timeout}s waiting for Vocdoni job #{job_id} (last status: #{job["status"].inspect})",
                body: job
              )
            end

            sleep(interval)
          end
        end

        private

        # @param job_id [String]
        # @param job [Hash] the failed job
        # @return [String]
        def failure_message(job_id, job)
          errors = Array(job["errors"]).map(&:to_s).compact_blank
          detail = errors.any? ? errors.join("; ") : "status #{job["status"].inspect}"

          "Vocdoni job #{job_id} failed: #{detail}"
        end

        # Monotonic so that a clock adjustment cannot extend or cut the wait.
        #
        # @return [Float]
        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
end
