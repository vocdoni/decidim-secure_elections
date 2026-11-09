# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe PurgeCspPinsJob do
        include_context "with concurrency and csp pins"

        let(:component) { create(:elections_component) }
        let(:election) { create(:election, :published, :ongoing, component:) }
        let!(:vocdoni_process) { create(:vocdoni_process, :published, election:) }
        let!(:question) { create(:election_question, election:) }

        def make_pin(attrs = {})
          CspPin.insert!({ # rubocop:disable Rails/SkipsModelValidations
            process_id: vocdoni_process.id,
            decidim_question_id: question.id,
            election_id: election.id,
            csp_root_id: "root-1",
            seed: SecureRandom.hex(12),
            voter_digest: SecureRandom.hex(32),
            address: "0x#{SecureRandom.hex(20)}",
            nullifier: "0x#{SecureRandom.hex(32)}",
            vote_confirmed_at: Time.current
          }.merge(attrs))
        end

        context "when the process has pins with addresses" do
          before { 2.times { make_pin } }

          it "NULLs address and nullifier and sets purged_at" do
            described_class.perform_now(vocdoni_process.id)

            CspPin.where(process_id: vocdoni_process.id).each do |pin|
              expect(pin.address).to be_nil
              expect(pin.nullifier).to be_nil
              expect(pin.purged_at).not_to be_nil
            end
          end

          it "keeps the voter_digest and vote_confirmed_at so confirmed counts stay accurate" do
            before_digests = CspPin
                             .where(process_id: vocdoni_process.id)
                             .pluck(:voter_digest, :vote_confirmed_at)

            described_class.perform_now(vocdoni_process.id)

            after = CspPin.where(process_id: vocdoni_process.id)
            expect(after.map { |p| [p.voter_digest, p.vote_confirmed_at.to_i] })
              .to match_array(before_digests.map { |d, t| [d, t.to_i] })
          end

          it "is idempotent: a second run changes nothing" do
            described_class.perform_now(vocdoni_process.id)
            first_purged = CspPin
                           .where(process_id: vocdoni_process.id)
                           .pluck(:purged_at)
                           .map(&:to_i)

            described_class.perform_now(vocdoni_process.id)

            # purged_at is set only once because address is already nil
            expect(CspPin.where(process_id: vocdoni_process.id).pluck(:purged_at).map(&:to_i))
              .to eq(first_purged)
          end
        end

        context "when no process exists for the given id" do
          it "returns without error" do
            expect { described_class.perform_now(0) }.not_to raise_error
          end
        end

        context "when pins are already purged (address is nil)" do
          before do
            CspPin.insert!({ # rubocop:disable Rails/SkipsModelValidations
                             process_id: vocdoni_process.id,
                             decidim_question_id: question.id,
                             election_id: election.id,
                             csp_root_id: "root-1",
                             seed: SecureRandom.hex(12),
                             voter_digest: SecureRandom.hex(32),
                             address: nil,
                             nullifier: nil,
                             purged_at: 1.day.ago,
                             vote_confirmed_at: Time.current
                           })
          end

          it "does not update already-purged pins" do
            original_purged_at = CspPin.where(process_id: vocdoni_process.id).pick(:purged_at)

            described_class.perform_now(vocdoni_process.id)

            expect(CspPin.where(process_id: vocdoni_process.id).pick(:purged_at).to_i)
              .to eq(original_purged_at.to_i)
          end
        end
      end
    end
  end
end
