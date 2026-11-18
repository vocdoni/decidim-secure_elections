# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe PublishElectionJob do
        subject(:job) { described_class.new }

        let(:two_fa_fields) { [] }
        let(:process) { create(:vocdoni_process, metadata: { "settings" => { "twofa_fields" => two_fa_fields } }) }
        let(:election) { process.election }
        let(:census) { double(count: 10) }

        before do
          job.instance_variable_set(:@election, election)
          job.instance_variable_set(:@process, process)
          allow(election).to receive_messages(census:, census_ready?: true)
        end

        it "declares the signer and ceil(eligible × 1.2) instead of a roster" do
          job.send(:prepare_census!)

          expect(job.send(:census_payload)).to eq(
            "attested" => { "signer" => process.signer_address, "maxCensusSize" => 12 },
            "twoFaFields" => []
          )
        end

        it "draws the attestation secrets once" do
          job.send(:prepare_census!)
          signer = process.reload.signer_address

          job.send(:prepare_census!)
          expect(process.reload.signer_address).to eq(signer)
        end

        context "with email 2FA" do
          let(:two_fa_fields) { ["email"] }

          it "asks the SaaS for an email code" do
            job.send(:prepare_census!)

            expect(job.send(:census_payload)["twoFaFields"]).to eq(["email"])
          end
        end

        context "with a 2FA channel Decidim cannot attest" do
          let(:two_fa_fields) { %w(email phone) }

          it "refuses it before anything reaches the SaaS" do
            expect { job.send(:prepare_census!) }.to raise_error(ApiError) do |error|
              expect(error.transient?).to be(false)
            end
            expect(process.reload.attestation_signer_key).to be_nil
          end
        end

        describe "the census readiness gate" do
          before { allow(election).to receive(:census_ready?).and_return(false) }

          it "refuses a census that is not ready" do
            expect { job.send(:prepare_census!) }.to raise_error(ApiError, /census is not ready/) do |error|
              expect(error.transient?).to be(false)
            end
          end
        end
      end
    end
  end
end
