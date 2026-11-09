# frozen_string_literal: true

# One row per Decidim question of an external-CSP process: the SaaS question
# id that seeds the per-question key and the public census root derived from
# it. Public data only; the roots that derive the keys never touch the DB.
class CreateDecidimVocdoniCspElections < ActiveRecord::Migration[8.0]
  def change
    create_table :decidim_vocdoni_csp_elections do |t|
      t.references :process, null: false, foreign_key: { to_table: :decidim_vocdoni_processes, on_delete: :restrict }
      t.bigint :decidim_question_id, null: false, index: { unique: true }
      # SaaS question ObjectID, 24 hex chars. Unique so that two questions
      # never share a key.
      t.string :seed, null: false, index: { unique: true }
      # Compressed secp256k1 public key, 66 hex chars.
      t.string :census_root, null: false
      # On-chain election id, known once the process is published.
      t.string :upstream_id, index: { unique: true, where: "upstream_id IS NOT NULL" }
      t.timestamps
    end
  end
end
