# frozen_string_literal: true

require "spec_helper"

# Every property here is enforced by Postgres (indexes, triggers, FKs), so
# each expectation runs against the real test database. A statement the
# trigger rejects aborts the transaction it runs in, so those run inside a
# savepoint (`requires_new: true`) and the example can keep using the
# connection afterwards.
module Decidim
  module Elections
    module Vocdoni
      describe CspPin do
        let(:process) { create(:vocdoni_process) }
        let(:question_id) { 4242 }
        let(:address) { SecureRandom.hex(20) }
        let(:nullifier) { SecureRandom.hex(32) }
        # The sign path inserts a pin with its address and nullifier at once;
        # afterwards they can only be purged.
        let!(:pin) { create(:vocdoni_csp_pin, process:, decidim_question_id: question_id, address:, nullifier:) }

        def in_savepoint(&)
          ActiveRecord::Base.transaction(requires_new: true, &)
        end

        def pin_row
          ActiveRecord::Base.connection.select_one(
            "SELECT * FROM decidim_vocdoni_csp_pins WHERE id = #{pin.id.to_i}"
          )
        end

        it "has both pins triggers installed and enabled" do
          expect(enabled_csp_pins_triggers)
            .to eq(%w(decidim_vocdoni_csp_pins_guard decidim_vocdoni_csp_pins_no_truncate))
        end

        describe "unique indexes" do
          it "rejects a second pin for the same question and voter digest" do
            expect do
              in_savepoint do
                create(:vocdoni_csp_pin, process:, decidim_question_id: question_id, voter_digest: pin.voter_digest)
              end
            end.to raise_error(ActiveRecord::RecordNotUnique, /index_vocdoni_csp_pins_on_question_and_digest/)
          end

          it "allows the same voter digest on another question" do
            expect { create(:vocdoni_csp_pin, process:, decidim_question_id: question_id + 1, voter_digest: pin.voter_digest) }
              .to change(described_class, :count).by(1)
          end

          it "rejects a second pin for the same question and address" do
            expect do
              in_savepoint { create(:vocdoni_csp_pin, process:, decidim_question_id: question_id, address:) }
            end.to raise_error(ActiveRecord::RecordNotUnique, /index_vocdoni_csp_pins_on_question_and_address/)
          end

          it "allows many pins without an address on one question" do
            create(:vocdoni_csp_pin, process:, decidim_question_id: question_id)
            create(:vocdoni_csp_pin, process:, decidim_question_id: question_id)
            expect(described_class.where(decidim_question_id: question_id, address: nil).count).to eq(2)
          end
        end

        describe "delete guard" do
          it "refuses delete_all" do
            expect { in_savepoint { described_class.where(id: pin.id).delete_all } }
              .to raise_error(ActiveRecord::StatementInvalid, /csp pins are never deleted/)
            expect(described_class.exists?(pin.id)).to be(true)
          end

          it "refuses TRUNCATE, which bypasses row triggers" do
            expect { in_savepoint { ActiveRecord::Base.connection.execute("TRUNCATE decidim_vocdoni_csp_pins") } }
              .to raise_error(ActiveRecord::StatementInvalid, /csp pins are never deleted/)
            expect(described_class.exists?(pin.id)).to be(true)
          end

          it "refuses TRUNCATE ... CASCADE from the processes table" do
            sql = "TRUNCATE decidim_vocdoni_processes CASCADE"
            expect { in_savepoint { ActiveRecord::Base.connection.execute(sql) } }
              .to raise_error(ActiveRecord::StatementInvalid, /csp pins are never deleted/)
            expect(described_class.exists?(pin.id)).to be(true)
          end

          it "aborts destroy in Ruby" do
            expect(pin.destroy).to be(false)
            expect(described_class.exists?(pin.id)).to be(true)
          end
        end

        describe "update guard" do
          it "refuses another address" do
            expect { in_savepoint { pin.update!(address: SecureRandom.hex(20)) } }
              .to raise_error(ActiveRecord::StatementInvalid, /address can only be purged/)
            expect(pin_row["address"]).to eq(address)
          end

          it "purges the address and the nullifier to NULL" do
            pin.update!(address: nil, nullifier: nil, purged_at: Time.current)
            expect(pin_row.values_at("address", "nullifier")).to eq([nil, nil])
          end

          it "refuses re-setting a purged address or nullifier" do
            pin.update!(address: nil, nullifier: nil)
            expect { in_savepoint { pin.update!(address:) } }
              .to raise_error(ActiveRecord::StatementInvalid, /address can only be purged/)
            pin.reload
            expect { in_savepoint { pin.update!(nullifier:) } }
              .to raise_error(ActiveRecord::StatementInvalid, /nullifier can only be purged/)
          end

          it "refuses giving an address to a pin inserted without one" do
            bare = create(:vocdoni_csp_pin, process:)
            expect { in_savepoint { bare.update!(address: SecureRandom.hex(20)) } }
              .to raise_error(ActiveRecord::StatementInvalid, /address can only be purged/)
          end

          it "refuses changing the nullifier to another value" do
            expect { in_savepoint { pin.update!(nullifier: SecureRandom.hex(32)) } }
              .to raise_error(ActiveRecord::StatementInvalid, /nullifier can only be purged/)
          end

          {
            voter_digest: -> { SecureRandom.hex(32) },
            decidim_question_id: -> { 1 },
            election_id: -> { 1 },
            csp_root_id: -> { "another-root" },
            seed: -> { SecureRandom.hex(12) }
          }.each do |column, value|
            it "refuses changing #{column}" do
              expect { in_savepoint { pin.update!(column => instance_exec(&value)) } }
                .to raise_error(ActiveRecord::StatementInvalid, /identity is immutable/)
            end
          end

          it "refuses moving the pin to another process" do
            other = create(:vocdoni_process)
            expect { in_savepoint { pin.update!(process_id: other.id) } }
              .to raise_error(ActiveRecord::StatementInvalid, /identity is immutable/)
          end

          it "sets vote_confirmed_at once and refuses changing or clearing it" do
            pin.update!(vote_confirmed_at: 1.minute.ago)
            expect { in_savepoint { pin.update!(vote_confirmed_at: Time.current) } }
              .to raise_error(ActiveRecord::StatementInvalid, /confirmation is final/)
            pin.reload
            expect { in_savepoint { pin.update!(vote_confirmed_at: nil) } }
              .to raise_error(ActiveRecord::StatementInvalid, /confirmation is final/)
          end
        end

        describe "scopes" do
          let!(:confirmed) { create(:vocdoni_csp_pin, process:, address: SecureRandom.hex(20), vote_confirmed_at: Time.current) }
          let!(:purged) { create(:vocdoni_csp_pin, process:, vote_confirmed_at: Time.current, purged_at: Time.current) }

          it "splits pins by confirmation and by live address" do
            expect(described_class.confirmed).to contain_exactly(confirmed, purged)
            expect(described_class.unconfirmed).to contain_exactly(pin)
            expect(described_class.live).to contain_exactly(pin, confirmed)
          end
        end

        describe "Process#destroy" do
          before { allow(ApiClient).to receive(:new).and_raise("SaaS must not be called") }

          it "deletes the csp elections of a process without pins" do
            other = create(:vocdoni_process)
            create(:vocdoni_csp_election, process: other)
            other.destroy!
            expect(CspElection.where(process_id: other.id)).to be_empty
            expect(Process.exists?(other.id)).to be(false)
          end

          it "refuses a process with pins before touching the SaaS draft" do
            process.update!(vocdoni_process_id: "6885f0c2c1a4e2f0b1d33a01")
            create(:vocdoni_csp_election, process:)
            expect { process.destroy }.to raise_error(ActiveRecord::DeleteRestrictionError)
            expect(ApiClient).not_to have_received(:new)
            expect(Process.exists?(process.id)).to be(true)
          end

          it "refuses a raw delete of a process with pins through the foreign key" do
            expect { in_savepoint { Process.where(id: process.id).delete_all } }
              .to raise_error(ActiveRecord::InvalidForeignKey)
          end
        end
      end

      # Specs that commit pins (non-transactional) clean up despite the delete
      # guard, and leave the guard enabled. Each example asserts both, so the
      # one that runs second proves the first one's cleanup.
      describe CspPin, "committed outside a test transaction" do
        include_context "with concurrency and csp pins"

        2.times do |i|
          it "starts clean with the guard on and cleans up its pin (#{i + 1})" do
            expect(described_class.count).to eq(0)
            expect(enabled_csp_pins_triggers.size).to eq(2)
            pin = create(:vocdoni_csp_pin, decidim_question_id: 7, voter_digest: "d" * 64)
            expect { pin.class.where(id: pin.id).delete_all }
              .to raise_error(ActiveRecord::StatementInvalid, /never deleted/)
          end
        end
      end
    end
  end
end
