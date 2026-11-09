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
        UPSTREAM_ID_FORMAT = /\A\h{64}\z/

        belongs_to :process, class_name: "Decidim::Elections::Vocdoni::Process", inverse_of: :csp_elections

        validates :decidim_question_id, presence: true
        validates :seed, format: { with: SEED_FORMAT }
        validates :census_root, format: { with: CENSUS_ROOT_FORMAT }
        validates :upstream_id, format: { with: UPSTREAM_ID_FORMAT }, allow_nil: true
        validate :upstream_id_written_once, on: :update

        # The on-chain election id as stored: 64 lower-case hex, no `0x`.
        def self.normalize_upstream_id(value) = value.to_s.strip.sub(/\A0x/i, "").downcase

        # The 12 seed bytes the per-election key derivation takes.
        def seed_bytes = [seed].pack("H*")

        # Records the on-chain election id the SaaS reports. It is written
        # once: the same id again is a no-op and a different one raises,
        # because every signed bundle binds the voter to this election id.
        def bind_upstream_id!(value)
          id = self.class.normalize_upstream_id(value)
          raise Csp::IntegrityError, "upstream id of question #{decidim_question_id} is not a 32-byte hex id" unless id.match?(UPSTREAM_ID_FORMAT)
          return self if upstream_id == id
          raise Csp::IntegrityError, "upstream id of question #{decidim_question_id} differs from the recorded one" if upstream_id.present?

          update!(upstream_id: id)
          self
        end

        private

        def upstream_id_written_once
          return unless upstream_id_changed? && upstream_id_was.present?

          errors.add(:upstream_id, "is written once")
        end
      end
    end
  end
end
