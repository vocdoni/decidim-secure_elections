# frozen_string_literal: true

# Stage A of Phase 4: the Vocdoni-specific state of an election lives in this
# sidecar table, alongside upstream's `decidim_elections_elections`.
#
# Sidecar (not subclass, not table alteration): the upstream Election table
# stays untouched — future upstream migrations touch their table, our
# migrations touch ours. The FK `decidim_election_id` links one Vocdoni
# Process to at most one Decidim Election.
class CreateDecidimVocdoniProcesses < ActiveRecord::Migration[8.0]
  def change
    create_table :decidim_vocdoni_processes do |t|
      # The upstream election this process materialises. Deleting the election
      # cascades to the sidecar — there is no Vocdoni state independent of a
      # Decidim election.
      t.references :decidim_election,
                   null: false,
                   foreign_key: { to_table: :decidim_elections_elections, on_delete: :cascade },
                   index: { unique: true, name: "index_vocdoni_processes_on_decidim_election_id" }

      # Vocdoni SaaS identifiers, populated by PublishToVocdoniJob after the
      # SaaS confirms the process is up on-chain. All nullable because the
      # sidecar exists before publish (see Vocdoni::AfterUpdateCensus, which
      # bootstraps it in state `pending` on Census save) and only gets ids
      # after the publish transition succeeds.
      #
      # Note: the admin-side census configuration (which identifier fields
      # to collect, two-factor toggles, weighted flag) lives in upstream's
      # `decidim_elections_elections.census_settings` jsonb, not here. That
      # column is populated by upstream's ProcessCensus command from the
      # form's `#census_settings` method. This sidecar is only about
      # post-publish state — the on-chain reality of the election.
      t.string :vocdoni_process_id, index: { unique: true, where: "vocdoni_process_id IS NOT NULL" }
      t.string :vocdoni_upstream_id
      t.string :chain_id

      # Lifecycle state as seen from the Vocdoni side. Independent of
      # Decidim's `Election#status`.
      #   pending    — sidecar exists, publish not yet attempted
      #   publishing — PublishToVocdoniJob is enqueued/in-flight
      #   published  — SaaS confirmed the process is on-chain
      #   failed     — publish attempt gave up permanently
      t.string :state, null: false, default: "pending"

      # Cached copy of the last non-transient error message from the SaaS,
      # so the admin dashboard can show it without hitting the API.
      t.string :last_error

      t.timestamps
    end
  end
end
