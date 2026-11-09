# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # The one signature a voter got for a question, bound to one ephemeral
      # address. Append-only: a database trigger forbids deleting a pin or
      # changing its identity, and lets `address`/`nullifier` change only to
      # NULL when they are purged. See the create_decidim_vocdoni_csp_pins
      # migration.
      class CspPin < ApplicationRecord
        self.table_name = "decidim_vocdoni_csp_pins"

        belongs_to :process, class_name: "Decidim::Elections::Vocdoni::Process", inverse_of: :csp_pins

        validates :decidim_question_id, :election_id, :csp_root_id, :seed, :voter_digest, presence: true

        scope :confirmed, -> { where.not(vote_confirmed_at: nil) }
        scope :unconfirmed, -> { where(vote_confirmed_at: nil) }
        scope :live, -> { where.not(address: nil) }

        # Fails in Ruby before the trigger has to.
        before_destroy { throw :abort }
      end
    end
  end
end
