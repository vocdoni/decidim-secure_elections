# frozen_string_literal: true

# State for the vote-driven live results sync (see `LiveResultsSync`). Plain
# columns rather than keys in `metadata`, so the atomic claim/release updates
# cannot be overwritten by a job saving the whole `metadata` hash.
class AddLiveResultsSyncToVocdoniProcesses < ActiveRecord::Migration[8.0]
  def change
    # Cast notifications accepted for this election, ever.
    add_column :decidim_vocdoni_processes, :live_sync_requests, :integer, null: false, default: 0
    # While in the future, a results-sync chain is in flight for this election.
    add_column :decidim_vocdoni_processes, :live_sync_until, :datetime
    # Sum of the per-question `voteCount` seen by the last results sync.
    add_column :decidim_vocdoni_processes, :synced_vote_count, :integer
  end
end
