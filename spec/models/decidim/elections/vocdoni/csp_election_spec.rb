# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe CspElection do
        subject(:csp_election) { build(:vocdoni_csp_election, seed: "65f0a1b2c3d4e5f60718293a") }

        it { is_expected.to be_valid }

        it "returns the 12 seed bytes" do
          expect(csp_election.seed_bytes).to eq(["65f0a1b2c3d4e5f60718293a"].pack("H*"))
          expect(csp_election.seed_bytes.bytesize).to eq(12)
        end

        it "rejects a malformed seed" do
          csp_election.seed = "65f0a1b2"
          expect(csp_election).not_to be_valid
        end

        it "rejects a census root that is not a compressed point" do
          csp_election.census_root = "04#{"ab" * 32}"
          expect(csp_election).not_to be_valid
        end

        describe "#bind_upstream_id!" do
          let(:upstream_id) { "ab" * 32 }

          before { csp_election.save! }

          it "stores a 0x-prefixed upper-case id as 64 lower-case hex" do
            csp_election.bind_upstream_id!("0x#{upstream_id.upcase}")
            expect(csp_election.reload.upstream_id).to eq(upstream_id)
          end

          it "accepts the same id again" do
            csp_election.bind_upstream_id!(upstream_id)
            expect { csp_election.bind_upstream_id!("0x#{upstream_id}") }.not_to raise_error
          end

          it "refuses a different id once one is recorded" do
            csp_election.bind_upstream_id!(upstream_id)
            expect { csp_election.bind_upstream_id!("cd" * 32) }.to raise_error(Csp::IntegrityError, /differs/)
            expect(csp_election.reload.upstream_id).to eq(upstream_id)
          end

          it "refuses an id that is not 32 bytes of hex" do
            expect { csp_election.bind_upstream_id!("ab" * 31) }.to raise_error(Csp::IntegrityError)
            expect(csp_election.reload.upstream_id).to be_nil
          end

          it "is invalid when a recorded id is rewritten" do
            csp_election.bind_upstream_id!(upstream_id)
            csp_election.upstream_id = "cd" * 32
            expect(csp_election).not_to be_valid
          end
        end

        describe "unique indexes" do
          let(:upstream_id) { "ab" * 32 }
          let!(:existing) { create(:vocdoni_csp_election, upstream_id:) }

          def save_in_savepoint(record)
            ActiveRecord::Base.transaction(requires_new: true) { record.save!(validate: false) }
          end

          it "rejects a second row for the same seed" do
            expect { save_in_savepoint(build(:vocdoni_csp_election, seed: existing.seed)) }
              .to raise_error(ActiveRecord::RecordNotUnique)
          end

          it "rejects a second row for the same question" do
            expect { save_in_savepoint(build(:vocdoni_csp_election, decidim_question_id: existing.decidim_question_id)) }
              .to raise_error(ActiveRecord::RecordNotUnique)
          end

          it "rejects a second row for the same upstream id and allows many without one" do
            expect { save_in_savepoint(build(:vocdoni_csp_election, upstream_id:)) }
              .to raise_error(ActiveRecord::RecordNotUnique)
            create(:vocdoni_csp_election)
            create(:vocdoni_csp_election)
            expect(described_class.where(upstream_id: nil).count).to eq(2)
          end
        end
      end
    end
  end
end
