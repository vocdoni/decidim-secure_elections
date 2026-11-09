# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # A Decidim question of an external-CSP process: the SaaS question id
      # that seeds its signing key and the public census root derived from it.
      class CspElection < ApplicationRecord
        self.table_name = "decidim_vocdoni_csp_elections"

        SEED_FORMAT = /\A\h{24}\z/
        CENSUS_ROOT_FORMAT = /\A0[23]\h{64}\z/

        belongs_to :process, class_name: "Decidim::Elections::Vocdoni::Process", inverse_of: :csp_elections

        validates :decidim_question_id, presence: true
        validates :seed, format: { with: SEED_FORMAT }
        validates :census_root, format: { with: CENSUS_ROOT_FORMAT }

        # The 12 seed bytes the per-election key derivation takes.
        def seed_bytes = [seed].pack("H*")
      end
    end
  end
end
