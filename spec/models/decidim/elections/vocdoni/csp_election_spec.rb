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

        describe "unique indexes" do
          let!(:existing) { create(:vocdoni_csp_election, upstream_id: "0xabc") }

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
            expect { save_in_savepoint(build(:vocdoni_csp_election, upstream_id: "0xabc")) }
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
