# frozen_string_literal: true

# Decidim as the external CSP of a process. `census_size` holds the census
# size declared on chain, so it needs no column of its own.
class AddCspToVocdoniProcesses < ActiveRecord::Migration[8.0]
  def change
    # Ids (never values) of the keyring root and the pin secret the process
    # was published with. Signing uses exactly this root and refuses another
    # pin secret, since a new one would change every voter digest.
    add_column :decidim_vocdoni_processes, :csp_root_id, :string
    add_column :decidim_vocdoni_processes, :pin_secret_id, :string

    # nil, "verified" or "compromised", from comparing the chain with the
    # roots Decidim derived. Kept apart from `state`, which the sync job
    # rewrites on every tick.
    add_column :decidim_vocdoni_processes, :csp_state, :string
    add_column :decidim_vocdoni_processes, :csp_verified_at, :datetime
  end
end
