# frozen_string_literal: true

# Stage B of Phase 4: PublishToVocdoniJob needs a place to record
#
#   * `census_group_id` — the Vocdoni memberbase group built for this election,
#     kept so a resumed publish reuses it instead of building a second one.
#     (See PublishElectionJob legacy for the "why retries are safe" reasoning.)
#   * `census_size` — turnout denominator surfaced in the dashboard.
#   * `metadata` — per-question upstream ids, chain-side statuses and anything
#     else that used to live on `Decidim::Elections::Vocdoni::Question` in the
#     standalone module. Keeping it as a bag on the sidecar keeps the schema
#     small; a proper `vocdoni_questions` table can be added later if we ever
#     need to query per-question.
class AddVocdoniProcessMetadata < ActiveRecord::Migration[8.0]
  def change
    add_column :decidim_vocdoni_processes, :census_group_id, :string
    add_column :decidim_vocdoni_processes, :census_size, :integer
    add_column :decidim_vocdoni_processes, :metadata, :jsonb, null: false, default: {}
  end
end
