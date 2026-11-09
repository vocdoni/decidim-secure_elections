# frozen_string_literal: true

# Attested census support on the `Vocdoni::Process` sidecar.
#
# `census_mode` picks how the SaaS learns who may vote: `memberbase` pushes the roster as
# organization members, `attested` signs an EIP-712 attestation per voter at booth time. The
# per-election signer key and voterId secret are stored encrypted with Decidim::AttributeEncryptor
# and never leave Decidim. `decidim_vocdoni_attestations` keeps one row per voterId the election
# attested, which is the issued count the admin compares with what the SaaS published.
class AddAttestationToVocdoniProcesses < ActiveRecord::Migration[8.0]
  def change
    change_table :decidim_vocdoni_processes, bulk: true do |t|
      t.string :census_mode, null: false, default: "memberbase"
      t.text :attestation_signer_key
      t.text :voter_id_secret
    end

    create_table :decidim_vocdoni_attestations do |t|
      t.references :decidim_vocdoni_process,
                   null: false,
                   foreign_key: { to_table: :decidim_vocdoni_processes, on_delete: :cascade },
                   index: false
      t.string :voter_id, null: false
      t.integer :issued_count, null: false, default: 1
      t.timestamps
    end
    add_index :decidim_vocdoni_attestations, [:decidim_vocdoni_process_id, :voter_id],
              unique: true, name: "index_vocdoni_attestations_on_process_and_voter"
  end
end
