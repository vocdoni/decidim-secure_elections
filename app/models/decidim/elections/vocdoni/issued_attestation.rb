# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # One voterId an attested election issued attestations for, with how many it issued. The rows
      # are the issued count the admin compares with the attestation records the SaaS publishes.
      class IssuedAttestation < ApplicationRecord
        self.table_name = "decidim_vocdoni_attestations"

        belongs_to :process,
                   class_name: "Decidim::Elections::Vocdoni::Process",
                   foreign_key: "decidim_vocdoni_process_id",
                   inverse_of: :issued_attestations

        validates :voter_id, presence: true
      end
    end
  end
end
