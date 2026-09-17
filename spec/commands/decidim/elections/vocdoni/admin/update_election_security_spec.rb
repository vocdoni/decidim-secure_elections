# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Vocdoni
      module Admin
        describe UpdateElectionSecurity do
          subject(:command) { described_class.new(form, election) }

          let(:election) { create(:election, census_manifest: "internal_users") }
          let(:form) { AdminForms::SecurityForm.new(enable_vocdoni:, email:) }
          let(:enable_vocdoni) { true }
          let(:email) { false }

          def sidecar
            Vocdoni::Process.find_by(decidim_election_id: election.id)
          end

          context "when the secret vote is chosen for the first time" do
            let(:email) { true }

            it "opts the election in with the email code" do
              expect { command.call }.to broadcast(:ok)

              expect(sidecar).to be_pending
              expect(sidecar.metadata["settings"]).to eq("twofa_fields" => %w(email))
            end

            it "leaves the census alone" do
              command.call

              expect(election.reload.census_manifest).to eq("internal_users")
            end
          end

          context "when an opted-in election changes its code" do
            before do
              Vocdoni::Process.create!(election:, state: "pending",
                                       metadata: { "settings" => { "twofa_fields" => %w(email) }, "questions" => [] })
            end

            it "updates the settings and keeps the rest of the sidecar" do
              expect { command.call }.to broadcast(:ok)

              expect(sidecar.metadata["settings"]).to eq("twofa_fields" => [])
              expect(sidecar.metadata).to have_key("questions")
            end
          end

          context "when an opted-in election goes back to a simple vote" do
            let(:enable_vocdoni) { false }

            before { Vocdoni::Process.create!(election:, state: "pending") }

            it "opts the election out" do
              expect { command.call }.to broadcast(:ok)

              expect(sidecar).to be_nil
            end
          end

          context "when a simple vote stays simple" do
            let(:enable_vocdoni) { false }

            it "creates nothing" do
              expect { command.call }.to broadcast(:ok)

              expect(sidecar).to be_nil
            end
          end

          context "when the election can no longer be edited" do
            let(:election) { create(:election, :published, :ongoing, census_manifest: "internal_users") }

            it "broadcasts invalid and changes nothing" do
              expect { command.call }.to broadcast(:invalid)

              expect(sidecar).to be_nil
            end
          end

          context "when it is a file census" do
            let(:fields) { %w(memberNumber name) }
            let(:election) { create(:election, census_manifest: "token_csv", census_settings: { "fields" => fields }) }
            let(:identifiers) { %w(memberNumber) }
            let(:form) { AdminForms::SecurityForm.new(election:, enable_vocdoni:, identifiers:) }

            context "when a simple vote is chosen" do
              let(:enable_vocdoni) { false }

              it "saves the chosen identifiers with the census, without creating a sidecar" do
                expect { command.call }.to broadcast(:ok)

                expect(election.reload.census_settings["identifiers"]).to eq(%w(memberNumber))
                expect(sidecar).to be_nil
              end
            end

            context "when a secure vote is chosen and the census already has people in it" do
              let(:enable_vocdoni) { true }

              before { Decidim::Elections::Voter.create!(election:, data: { "memberNumber" => "1" }) }

              it "marks the census pre-flight as pending and enqueues it" do
                expect { command.call }.to broadcast(:ok).and have_enqueued_job(Vocdoni::PreflightCensusJob).with(election.id)

                expect(sidecar).to be_census_validation_pending
              end
            end

            context "when the chosen identifiers are invalid" do
              let(:identifiers) { [] }
              let(:enable_vocdoni) { false }

              it "broadcasts invalid and saves nothing" do
                expect { command.call }.to broadcast(:invalid)

                expect(election.reload.census_settings["identifiers"]).to be_nil
                expect(sidecar).to be_nil
              end
            end
          end
        end
      end
    end
  end
end
