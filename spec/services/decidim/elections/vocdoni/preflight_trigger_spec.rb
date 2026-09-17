# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Vocdoni
      describe PreflightTrigger do
        subject(:call) { described_class.call(election) }

        let(:election) { create(:election, census_manifest: "token_csv") }

        def sidecar
          Vocdoni::Process.find_by(decidim_election_id: election.id)
        end

        context "when the election never opted in to Vocdoni" do
          it "does nothing" do
            expect { call }.not_to have_enqueued_job(PreflightCensusJob)
          end

          it "returns false" do
            expect(call).to be(false)
          end
        end

        context "when the sidecar is already published" do
          before { Vocdoni::Process.create!(election:, state: "published", vocdoni_process_id: "abc123") }

          it "does nothing: an on-chain process is not re-checked" do
            expect { call }.not_to have_enqueued_job(PreflightCensusJob)
          end

          it "returns false" do
            expect(call).to be(false)
          end
        end

        context "when the sidecar already points at a Vocdoni process" do
          before { Vocdoni::Process.create!(election:, state: "publishing", vocdoni_process_id: "abc123") }

          it "does nothing" do
            expect { call }.not_to have_enqueued_job(PreflightCensusJob)
          end
        end

        context "when the election opted in but its census is not ready" do
          before do
            Vocdoni::Process.create!(election:, state: "pending",
                                     metadata: { "census_validation" => { "ok" => true, "size" => 3 } },
                                     census_group_id: "old-group")
          end

          it "clears the previous validation and the stale group id, without queueing a job" do
            expect { call }.not_to have_enqueued_job(PreflightCensusJob)

            sidecar.reload
            expect(sidecar.census_validation).to be_nil
            expect(sidecar.census_group_id).to be_nil
          end

          it "returns false" do
            expect(call).to be(false)
          end
        end

        context "when the election opted in and its census is ready" do
          before do
            Vocdoni::Process.create!(election:, state: "pending", census_group_id: "old-group")
            Decidim::Elections::Voter.create!(election:, data: { "name" => "Ada" })
          end

          it "marks the validation pending, resets the stale group id and queues the pre-flight" do
            expect { call }.to have_enqueued_job(PreflightCensusJob).with(election.id)

            sidecar.reload
            expect(sidecar).to be_census_validation_pending
            expect(sidecar.census_group_id).to be_nil
          end

          it "returns true" do
            expect(call).to be(true)
          end
        end
      end
    end
  end
end
