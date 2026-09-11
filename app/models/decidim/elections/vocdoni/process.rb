# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Vocdoni-specific state of a Decidim election, kept in the sidecar
      # `decidim_vocdoni_processes` table so upstream's `decidim_elections_elections`
      # stays untouched.
      #
      # See db/migrate/20260911120001_create_decidim_vocdoni_processes.rb for
      # the shape and the reasoning.
      class Process < ApplicationRecord
        self.table_name = "decidim_vocdoni_processes"

        STATES = %w(pending publishing published failed).freeze

        belongs_to :election,
                   class_name: "Decidim::Elections::Election",
                   foreign_key: "decidim_election_id",
                   inverse_of: :vocdoni_process

        validates :state, inclusion: { in: STATES }
        validates :vocdoni_process_id, uniqueness: true, allow_nil: true

        scope :pending,    -> { where(state: "pending") }
        scope :publishing, -> { where(state: "publishing") }
        scope :published,  -> { where(state: "published") }
        scope :failed,     -> { where(state: "failed") }

        def pending?    = state == "pending"
        def publishing? = state == "publishing"
        def published?  = state == "published"
        def failed?     = state == "failed"

        # Per-question upstream ids and chain-side statuses. Written by
        # PublishToVocdoniJob after the process is on chain; read by the voter
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

        # Records the last non-transient publish failure. Used by the dashboard
        # to surface something actionable instead of a stuck wizard.
        def record_failure!(message, step: nil)
          self.metadata = metadata.merge(
            "last_error" => {
              "message" => message.to_s,
              "step" => step.presence&.to_s,
              "at" => Time.current.iso8601
            }.compact
          )
          self.last_error = message.to_s.truncate(255)
          self.state = "failed"
          save!
        end
      end
    end
  end
end
