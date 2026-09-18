# frozen_string_literal: true

# The `Vocdoni::Process` sidecar attached to an upstream
# `Decidim::Elections::Election`. Presence of this row is what marks an
# election as Vocdoni-backed; its lifecycle mirrors what happens on chain.
#
# Sidecar (not subclass, not table alteration): the upstream Election table
# stays untouched — future upstream migrations touch their table, this
# migration touches ours. The FK `decidim_election_id` links one Vocdoni
# Process to at most one Decidim Election, and deleting the election
# cascades to the sidecar.
class CreateVocdoniProcesses < ActiveRecord::Migration[8.0]
  def change
    create_table :decidim_vocdoni_processes do |t|
      t.references :decidim_election,
                   null: false,
                   foreign_key: { to_table: :decidim_elections_elections, on_delete: :cascade },
                   index: { unique: true, name: "index_vocdoni_processes_on_decidim_election_id" }

      # Vocdoni SaaS identifiers, populated by PublishElectionJob after the
      # SaaS confirms the process is up on-chain. All nullable because the
      # sidecar exists before publish (bootstrapped in state `pending` when
      # the admin opts in on the Security tab) and only gets ids after the
      # publish transition succeeds.
      t.string :vocdoni_process_id, index: { unique: true, where: "vocdoni_process_id IS NOT NULL" }
      t.string :vocdoni_upstream_id
      t.string :chain_id

      # Lifecycle state as seen from the Vocdoni side, independent of
      # Decidim's `Election#status`:
      #   pending    — sidecar exists, publish not yet attempted
      #   publishing — PublishElectionJob is enqueued/in-flight
      #   published  — SaaS confirmed the process is on-chain
      #   failed     — publish attempt gave up permanently
      t.string :state, null: false, default: "pending"

      # Cached copy of the last non-transient error message from the SaaS,
      # so the admin dashboard can show it without hitting the API.
      t.string :last_error

      # Vocdoni memberbase group built for this election, kept so a resumed
      # publish reuses it instead of building a second one.
      t.string :census_group_id

      # Turnout denominator surfaced in the dashboard.
      t.integer :census_size

      # Per-question upstream ids, chain-side statuses and other post-publish
      # bookkeeping. A bag on the sidecar keeps the schema small; a proper
      # `vocdoni_questions` table can be added later if we ever need to query
      # per-question.
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end
  end
end
