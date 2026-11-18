# frozen_string_literal: true

# The census is attested, so no election builds a member group on the SaaS.
class RemoveCensusGroupIdFromVocdoniProcesses < ActiveRecord::Migration[8.0]
  def change
    remove_column :decidim_vocdoni_processes, :census_group_id, :string
  end
end
