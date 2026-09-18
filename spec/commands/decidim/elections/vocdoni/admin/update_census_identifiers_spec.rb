# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Vocdoni
      module Admin
        describe UpdateCensusIdentifiers do
          subject(:command) { described_class.new(form, election, user) }

          let(:organization) { create(:organization) }
          let(:user) { create(:user, :admin, :confirmed, organization:) }
          let(:fields) { %w(name surname email) }
          let(:election) do
            create(:election, census_manifest: "token_csv",
                              census_settings: {
                                "fields" => fields,
                                "columns" => [{ "header" => "Name", "field" => "name" }],
                                "file" => { "name" => "people.csv", "rows" => 1 }
                              })
          end
          let(:identifiers) { %w(name) }
          let(:form) { AdminForms::CensusIdentifiersForm.new(election:, identifiers:) }

          it "stores the chosen identifiers, keeping the rest of the census settings" do
            expect { command.call }.to broadcast(:ok)

            election.reload
            expect(election.census_settings["identifiers"]).to eq(%w(name))
            expect(election.census_settings["fields"]).to eq(fields)
            expect(election.census_settings["columns"]).to eq([{ "header" => "Name", "field" => "name" }])
            expect(election.census_settings["file"]["name"]).to eq("people.csv")
          end

          context "when the election can no longer be edited" do
            let(:election) do
              create(:election, :published, :ongoing, census_manifest: "token_csv",
                                                      census_settings: { "fields" => fields, "identifiers" => %w(surname) })
            end

            it "broadcasts invalid and changes nothing" do
              expect { command.call }.to broadcast(:invalid)

              expect(election.reload.census_settings["identifiers"]).to eq(%w(surname))
            end
          end

          context "when the chosen identifiers are invalid" do
            let(:identifiers) { [] }

            it "broadcasts invalid and saves nothing" do
              expect { command.call }.to broadcast(:invalid)

              expect(election.reload.census_settings["identifiers"]).to be_nil
            end
          end

          context "when the election opted in to Vocdoni" do
            before do
              Decidim::Elections::Voter.create!(election:, data: { "name" => "Ada" })
              Vocdoni::Process.create!(election:, state: "pending")
            end

            it "queues a fresh census pre-flight" do
              expect { command.call }.to have_enqueued_job(Vocdoni::PreflightCensusJob).with(election.id)

              expect(Vocdoni::Process.find_by(decidim_election_id: election.id)).to be_census_validation_pending
            end
          end

          context "when the election has not opted in to Vocdoni" do
            it "queues nothing" do
              expect { command.call }.not_to have_enqueued_job(Vocdoni::PreflightCensusJob)
            end
          end
        end
      end
    end
  end
end
