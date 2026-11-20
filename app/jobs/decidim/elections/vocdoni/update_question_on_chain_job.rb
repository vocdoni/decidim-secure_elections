# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Mirrors a per-question admin action onto that question's own Vochain
      # election. A `per_question` process is published with every question
      # `PAUSED`:
      #
      # * `enable_voting`   — the question goes `READY`, so ballots land.
      # * `publish_results` — the question goes `ENDED`, which closes it and
      #   makes the chain reveal its encrypted tally; the tally is then pulled
      #   into Decidim for that question only.
      #
      # Enqueued from the `subscribe_to_question_status` subscriber and from
      # {PublishElectionJob}, which replays actions taken before the process
      # reached the chain.
      #
      # The job acts on the question as it is when the job runs, not when it
      # was queued: an action Decidim has moved past is dropped, and the chain
      # status is read live before deciding to skip the move.
      #
      # Closing fails closed. Once Decidim shows a question's results, the
      # chain question must stop taking ballots, so `publish_results` retries
      # on any SaaS error for about an hour and every failure stays on the
      # admin dashboard (`Process#question_failures`) until the move succeeds.
      class UpdateQuestionOnChainJob < ApplicationJob
        include BusyRetry

        queue_as :vocdoni

        # Only `enable_voting` re-raises, and only a transient error.
        # `publish_results` schedules its own retries (see #retry_close).
        retry_on Decidim::Elections::Vocdoni::ApiError, wait: :polynomially_longer, attempts: 3

        TARGET_STATUS = {
          "enable_voting" => "READY",
          "publish_results" => "ENDED"
        }.freeze

        # Live chain statuses that already satisfy each target.
        REACHED_STATUSES = {
          "READY" => %w(READY ONGOING),
          "ENDED" => %w(ENDED RESULTS)
        }.freeze

        # A question in one of these is never moved again (in particular,
        # never reopened).
        TERMINAL_STATUSES = %w(ENDED RESULTS CANCELED).freeze

        # The schedule SyncElectionResultsJob polls a tally on: short waits
        # first, then every two minutes, about an hour in total.
        CLOSE_ATTEMPTS = SyncElectionResultsJob::MAX_POLL_ATTEMPTS

        def self.close_delay(attempt)
          SyncElectionResultsJob.poll_delay(attempt)
        end

        # While {PublishElectionJob} is pushing the process (about 15 s, longer
        # for a large census), the job waits for it: 40 checks 15 s apart
        # cover 10 minutes. This backs up the publish job's own replay, which
        # a worker crash between the two steps would lose.
        PUBLISH_WAIT_ATTEMPTS = 40
        PUBLISH_WAIT_S = 15

        # The {Process#pending_actions} key of a question action.
        def self.pending_key(question_id, action)
          "question_#{question_id}_#{action}"
        end

        def perform(question_id, action, attempt: 1, publish_wait: 0, busy: {})
          @action = action.to_s
          @attempt = attempt
          @publish_wait = publish_wait
          status = TARGET_STATUS[@action]
          raise ArgumentError, "Unknown question action #{action.inspect}" if status.nil?

          @question = Decidim::Elections::Question.find_by(id: question_id)
          return if question.blank?

          vocdoni_question_id = on_chain_id
          return wait_for_publish if vocdoni_question_id.blank?

          land!(vocdoni_question_id, status)
        rescue Decidim::Elections::Vocdoni::ApiError => e
          outcome = wait_out_busy(e, pending_key, busy) do |delay, args|
            self.class.set(wait: delay.seconds).perform_later(question.id, action, attempt:, **args)
          end
          return if outcome

          end_busy_wait(pending_key)
          closing? ? retry_close(e) : record_enable_failure(e)
        end

        private

        attr_reader :process, :question, :action, :attempt, :publish_wait

        def closing?
          action == "publish_results"
        end

        # Moves the question unless Decidim moved past the action, and clears
        # its failure and pending entries; a close also syncs the tally.
        def land!(vocdoni_question_id, status)
          if stale?
            process.clear_pending_action!(pending_key)
            return
          end

          reached = reach!(vocdoni_question_id, status)
          process.clear_question_failure!(question.id)
          process.clear_pending_action!(pending_key)

          # No SyncProcessJob here: one is already looping while voting is
          # open, and each enqueue would start another loop.
          return unless reached && status == "ENDED"

          Decidim::Elections::Vocdoni::SyncElectionResultsJob.perform_later(election.id, question_ids: [question.id])
        end

        def pending_key
          self.class.pending_key(question.id, action)
        end

        # The action the question's current Decidim state calls for, or nil
        # for a question that was never enabled.
        def current_action
          if question.published_results? then "publish_results"
          elsif question.voting_enabled_at.present? then "enable_voting"
          end
        end

        # An action queued before a later one (an `enable_voting` retried
        # after the results were published, for one) must not undo it.
        def stale?
          current = current_action
          return false if current == action

          Rails.logger.info "[vocdoni] question ##{question.id} is at #{current || "disabled"} in Decidim; " \
                            "dropping a stale #{action}"
          true
        end

        # Moves the chain question to `status` unless the live status already
        # satisfies it. Returns false when the question is terminal on chain
        # and cannot reach `status`.
        def reach!(vocdoni_question_id, status)
          live = live_status(vocdoni_question_id)

          if REACHED_STATUSES.fetch(status).include?(live)
            Rails.logger.info "[vocdoni] question ##{question.id} already #{live} on chain; skipping SaaS call"
          elsif TERMINAL_STATUSES.include?(live)
            Rails.logger.warn "[vocdoni] question ##{question.id} is #{live} on chain; not moving it to #{status}"
            return false
          else
            move!(vocdoni_question_id, status)
          end
          true
        end

        # The question's status as the SaaS reports it now, or nil when it
        # cannot be read: the move is then attempted, and a move to the status
        # the question already has fails and is retried like any other.
        def live_status(vocdoni_question_id)
          remote = Array(client.elections.get(process.vocdoni_process_id).to_h["questions"]).grep(Hash).find do |row|
            (row["id"] || row["questionId"]).to_s == vocdoni_question_id.to_s
          end
          remote.to_h["status"].to_s.upcase.presence
        rescue Decidim::Elections::Vocdoni::ApiError => e
          Rails.logger.warn "[vocdoni] could not read the chain status of question ##{question.id} " \
                            "(#{redact(e.message)}); moving it anyway"
          nil
        end

        def move!(vocdoni_question_id, status)
          Decidim::Elections::Vocdoni.validate_configuration!
          response = client.elections.bulk_set_question_status(
            process.vocdoni_process_id, status:, question_ids: [vocdoni_question_id]
          ).to_h
          await_job!(response["jobId"])
          Rails.logger.info "[vocdoni] moved question ##{question.id} of election ##{election.id} to #{status}"
        end

        # Any error, transient or not, is retried: the question stays open on
        # chain, taking ballots and hiding its tally, until the move lands.
        def retry_close(error)
          message = redact(error.message)
          gave_up = attempt >= CLOSE_ATTEMPTS
          process.record_question_failure!(
            question.id, message, step: "question_#{action}", code: error.try(:code), retries: { attempts: attempt, gave_up: }
          )

          if gave_up
            Rails.logger.error "[vocdoni] gave up closing question ##{question.id} on chain after #{attempt} attempts: #{message}"
          else
            delay = self.class.close_delay(attempt)
            Rails.logger.warn "[vocdoni] closing question ##{question.id} on chain failed " \
                              "(attempt #{attempt}/#{CLOSE_ATTEMPTS}): #{message}; retrying in #{delay}s"
            self.class.set(wait: delay.seconds).perform_later(question.id, action, attempt: attempt + 1)
          end
        end

        def record_enable_failure(error)
          process.record_question_failure!(question.id, redact(error.message), step: "question_#{action}", code: error.try(:code))
          raise error if error.transient?
        end

        # Runs the action again shortly while the process is being pushed.
        # Both this and the publish job's replay may then reach the question;
        # the second one finds it already moved (#reach! reads the live
        # status, and the SaaS treats a move to the current status as done).
        def wait_for_publish
          return unless process&.publishing?
          return if stale?

          if publish_wait >= PUBLISH_WAIT_ATTEMPTS
            Rails.logger.warn "[vocdoni] question ##{question.id}: the process is still publishing after " \
                              "#{publish_wait} checks; leaving #{action} to PublishElectionJob"
            return
          end

          self.class.set(wait: PUBLISH_WAIT_S.seconds).perform_later(question.id, action, publish_wait: publish_wait + 1)
        end

        # The question's SaaS id, or nil while the process is not on chain:
        # PublishElectionJob replays the action once it is.
        def on_chain_id
          @election = question.election
          @process = election.vocdoni_process
          return nil if process.blank? || !process.published? || process.vocdoni_process_id.blank?

          row = process.questions_metadata.find { |meta| meta["decidim_question_id"].to_i == question.id }
          row.to_h["vocdoni_question_id"].presence
        end
      end
    end
  end
end
