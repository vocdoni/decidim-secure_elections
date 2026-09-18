# frozen_string_literal: true

require "decidim/faker/localized"
require "decidim/core/test/factories"
require "decidim/participatory_processes/test/factories"
require "decidim/elections/test/factories"

# Guarded so that requiring this file twice — which happens as soon as a second
# module depends on it — redefines nothing.
unless FactoryBot::Internal.factories.registered?(:vocdoni_process)
  FactoryBot.define do
    # The `Vocdoni::Process` sidecar attached to an upstream
    # `Decidim::Elections::Election` when an admin opts in via the Security
    # tab. Presence of this row is what marks an election as Vocdoni-backed;
    # its `state` mirrors the on-chain lifecycle.
    factory :vocdoni_process, class: "Decidim::Elections::Vocdoni::Process" do
      transient do
        skip_injection { false }
      end

      election { create(:election, skip_injection:) }
      state { "pending" }
      metadata { {} }

      trait :publishing do
        state { "publishing" }
      end

      trait :published do
        state { "published" }
        vocdoni_process_id { "6885f0c2c1a4e2f0b1d33a01" }
        chain_id { "vocdoni/LTS/1.2" }
      end

      trait :with_two_factor do
        metadata { { "settings" => { "twofa_fields" => ["email"] } } }
      end
    end
  end
end
