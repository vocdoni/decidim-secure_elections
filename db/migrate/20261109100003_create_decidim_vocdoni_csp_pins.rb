# frozen_string_literal: true

# Append-only record of every signature Decidim issued as the external CSP:
# one pin per (question, voter), bound to one ephemeral address. The pin is
# what stops a voter from getting a second signature for another address, so
# the database enforces it on its own:
# - unique (question, voter digest) and (question, address);
# - a trigger forbids DELETE and TRUNCATE and any change to the identity
#   columns, and lets address and nullifier change only to NULL (purge).
#
# Loading `schema.rb` drops the triggers, so `Vocdoni.csp_ready!` refuses to
# sign or publish when they are missing.
class CreateDecidimVocdoniCspPins < ActiveRecord::Migration[8.0]
  def up
    create_table :decidim_vocdoni_csp_pins do |t|
      t.references :process, null: false, foreign_key: { to_table: :decidim_vocdoni_processes, on_delete: :restrict }
      t.bigint :decidim_question_id, null: false
      t.bigint :election_id, null: false
      t.string :csp_root_id, null: false
      t.string :seed, null: false
      t.string :voter_digest, null: false
      t.string :address
      t.string :nullifier
      t.datetime :vote_confirmed_at
      t.datetime :purged_at
      t.timestamps
    end
    add_index :decidim_vocdoni_csp_pins, [:decidim_question_id, :voter_digest],
              unique: true, name: "index_vocdoni_csp_pins_on_question_and_digest"
    add_index :decidim_vocdoni_csp_pins, [:decidim_question_id, :address],
              unique: true, where: "address IS NOT NULL", name: "index_vocdoni_csp_pins_on_question_and_address"

    execute <<~SQL.squish
      CREATE FUNCTION decidim_vocdoni_csp_pins_guard() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'csp pins are never deleted'; END IF;
        IF NEW.process_id IS DISTINCT FROM OLD.process_id
           OR NEW.decidim_question_id IS DISTINCT FROM OLD.decidim_question_id
           OR NEW.election_id IS DISTINCT FROM OLD.election_id
           OR NEW.csp_root_id IS DISTINCT FROM OLD.csp_root_id
           OR NEW.seed IS DISTINCT FROM OLD.seed
           OR NEW.voter_digest IS DISTINCT FROM OLD.voter_digest THEN
          RAISE EXCEPTION 'csp pin identity is immutable';
        END IF;
        IF NEW.address IS DISTINCT FROM OLD.address AND NEW.address IS NOT NULL THEN
          RAISE EXCEPTION 'csp pin address can only be purged';
        END IF;
        IF NEW.nullifier IS DISTINCT FROM OLD.nullifier AND NEW.nullifier IS NOT NULL THEN
          RAISE EXCEPTION 'csp pin nullifier can only be purged';
        END IF;
        IF OLD.vote_confirmed_at IS NOT NULL AND NEW.vote_confirmed_at IS DISTINCT FROM OLD.vote_confirmed_at THEN
          RAISE EXCEPTION 'csp pin confirmation is final';
        END IF;
        RETURN NEW;
      END $$ LANGUAGE plpgsql;
    SQL
    execute <<~SQL.squish
      CREATE TRIGGER decidim_vocdoni_csp_pins_guard BEFORE UPDATE OR DELETE ON decidim_vocdoni_csp_pins
        FOR EACH ROW EXECUTE FUNCTION decidim_vocdoni_csp_pins_guard();
    SQL

    # Row triggers do not fire on TRUNCATE.
    execute <<~SQL.squish
      CREATE FUNCTION decidim_vocdoni_csp_pins_no_truncate() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'csp pins are never deleted';
      END $$ LANGUAGE plpgsql;
    SQL
    execute <<~SQL.squish
      CREATE TRIGGER decidim_vocdoni_csp_pins_no_truncate BEFORE TRUNCATE ON decidim_vocdoni_csp_pins
        FOR EACH STATEMENT EXECUTE FUNCTION decidim_vocdoni_csp_pins_no_truncate();
    SQL
  end

  # Pins are evidence of who got a signature; no migration removes them.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
