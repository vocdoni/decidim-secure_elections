# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Vocdoni-specific state of a Decidim election, kept in the sidecar
      # `decidim_vocdoni_processes` table so upstream's `decidim_elections_elections`
      # stays untouched.
      #
      # See db/migrate/20260918150001_create_vocdoni_processes.rb for the
      # shape and the reasoning.
      class Process < ApplicationRecord
        self.table_name = "decidim_vocdoni_processes"

        STATES = %w(pending publishing published failed).freeze

        belongs_to :election,
                   class_name: "Decidim::Elections::Election",
                   foreign_key: "decidim_election_id",
                   inverse_of: :vocdoni_process

        validates :state, inclusion: { in: STATES }
        validates :vocdoni_process_id, uniqueness: true, allow_nil: true

        # Once the election on chain is anchored the draft is gone from SaaS
        # (a published process is not a draft any more), so `DELETE` no longer
        # applies. Only unpublished drafts need cleanup — that is, the sidecar
        # holds a `vocdoni_process_id` (the create step succeeded) but the
        # publish step never turned the row `state = "published"`. Without
        # this hook, destroying the Decidim election (which cascades here via
        # `has_one :vocdoni_process, dependent: :destroy`) would orphan the
        # draft on SaaS and eat one of the org's two draft slots — see
        # `40031 max drafts reached`.
        #
        # The DELETE runs inside the enclosing `Election#destroy` transaction:
        # if it raises the whole destroy rolls back and the admin gets to
        # retry, so we never end up with a Decidim election gone but its
        # SaaS draft still hanging around.
        before_destroy :delete_upstream_draft, if: :upstream_draft?

        scope :pending, -> { where(state: "pending") }
        scope :publishing, -> { where(state: "publishing") }
        scope :published, -> { where(state: "published") }
        scope :failed, -> { where(state: "failed") }

        def pending? = state == "pending"

        def publishing? = state == "publishing"

        def published? = state == "published"

        def failed? = state == "failed"

        # SaaS 402 codes for a publish the integrator's wallet cannot pay:
        # wallet short (40175), payment required (40178), spend cap (40183).
        BILLING_ERROR_CODES = [40_175, 40_178, 40_183].freeze

        def billing_failure? = BILLING_ERROR_CODES.include?(metadata.to_h.dig("last_error", "code").to_i)

        # What the refused publish costs, in euros, when the SaaS said so.
        def billing_required_eur
          cents = metadata.to_h.dig("last_error", "data", "requiredCents")
          cents.to_i / 100.0 if cents.to_i.positive?
        end

        # Per-question upstream ids and chain-side statuses. Written by
        # PublishElectionJob after the process is on chain; read by the voter
        # booth and the results-sync job.
        #
        # Shape:
        #   [
        #     { "decidim_question_id" => 42,
        #       "vocdoni_question_id" => "0x…",
        #       "vocdoni_upstream_id" => "0x…",
        #       "vocdoni_status"      => "ready" },
        #     …
        #   ]
        def questions_metadata
          Array(metadata["questions"])
        end

        def questions_metadata=(list)
          self.metadata = metadata.merge("questions" => Array(list))
        end

        # A row is a "SaaS draft" — a process created via `POST /processes`
        # that never made it to `POST /processes/{id}/publish` — when it has
        # an upstream id but is not yet in `published` state on our side. A
        # row currently `publishing` is also considered a draft for this
        # purpose: from SaaS's perspective it is a draft until the async
        # publish job completes, and if the publish is failing we do want it
        # cleaned up.
        def upstream_draft?
          vocdoni_process_id.present? && !published?
        end

        # Best-effort DELETE against the SaaS. Runs in the enclosing
        # `Election#destroy` transaction: any raise rolls the destroy back.
        #
        # Codes we accept as success:
        # - 2xx: gone as requested.
        # - 404: already gone (a manual purge, a previous partial destroy).
        # - 40012 (`ErrDuplicateConflict`, "process already published and not
        #   in draft mode"): the process crossed onto the chain while our
        #   sidecar still said `publishing`. There is nothing to delete
        #   anymore — the destroy of the sidecar row is fine, though the
        #   on-chain process is not going anywhere.
        #
        # Anything else — a scope 40158, an auth 40001, a network flap, a
        # 5xx — is a real failure and MUST raise so the destroy rolls back.
        def delete_upstream_draft
          Decidim::Elections::Vocdoni::ApiClient.new.elections.delete(vocdoni_process_id)
        rescue Decidim::Elections::Vocdoni::ApiError => e
          return if e.status == 404 || e.code == 40_012

          raise
        end

        # Records the last non-transient publish failure. Used by the dashboard
        # to surface something actionable instead of a stuck wizard.
        #
        # `data` keeps the SaaS's structured error payload — the `duplicates`,
        # `missingData` and `notFound` lists from a census validation 400 —
        # so the admin sees *which* voters are the problem, not just "invalid
        # data provided".
        #
        # `keep_state` records the error without marking the process failed,
        # for a step whose failure leaves the rest of the election usable.
        def record_failure!(message, step: nil, code: nil, data: nil, keep_state: false)
          self.metadata = metadata.merge(
            "last_error" => {
              "message" => message.to_s,
              "step" => step.presence&.to_s,
              "code" => code,
              "data" => data.presence,
              "at" => Time.current.iso8601
            }.compact
          )
          self.last_error = message.to_s.truncate(255)
          self.state = "failed" unless keep_state
          save!
        end

        # Chain status changes that failed for one question of a
        # `per_question` election, keyed by Decidim question id (a string).
        # Each entry stays until that question reaches its status on chain, so
        # the admin dashboard keeps showing it while Decidim and the chain
        # disagree.
        def question_failures
          metadata["question_failures"].to_h
        end

        # Records the failure for the question as well as in `last_error`. The
        # process stays `published`: the other questions keep voting.
        # `retries` is `{ attempts:, gave_up: }` for a job that retries on its
        # own: the tries made so far and whether it stopped.
        def record_question_failure!(question_id, message, step:, code: nil, retries: {})
          with_lock do
            entry = { "message" => message.to_s, "step" => step.to_s, "code" => code,
                      "attempts" => retries[:attempts], "gave_up" => retries.fetch(:gave_up, false),
                      "at" => Time.current.iso8601 }.compact
            self.metadata = metadata.merge("question_failures" => question_failures.merge(question_id.to_s => entry))
            record_failure!(message, step:, code:, keep_state: true)
          end
        end

        def clear_question_failure!(question_id)
          return unless question_failures.has_key?(question_id.to_s)

          with_lock do
            self.metadata = metadata.merge("question_failures" => question_failures.except(question_id.to_s))
            save!
          end
        end
      end
    end
  end
end
