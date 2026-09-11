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
      end
    end
  end
end
