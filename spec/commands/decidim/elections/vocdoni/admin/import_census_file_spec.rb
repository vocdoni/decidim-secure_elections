# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Vocdoni
      module Admin
        describe ImportCensusFile do
          subject(:command) { described_class.new(form, election, user) }

          let(:organization) { create(:organization) }
          let(:user) { create(:user, :admin, :confirmed, organization:) }
          let(:election) { create(:election) }

          let(:content) do
            <<~CSV
              Nombre,Correo
              Rosalind,rosalind@example.org
              Grace,grace@example.org
            CSV
          end

          let(:columns) { { "0" => "name", "1" => "email" } }
          let(:identifiers) { %w(email) }

          let(:blob) do
            ActiveStorage::Blob.create_and_upload!(
              io: StringIO.new(content),
              filename: "people.csv",
              content_type: "text/csv"
            )
          end

          let(:form) { AdminForms::CensusFileMappingForm.from_params(census_file: { blob: blob.signed_id, columns:, identifiers: }) }

          it "imports every row as a voter" do
            expect { command.call }.to broadcast(:ok, 2)

            expect(election.voters.count).to eq(2)
          end

          it "sets the census type and settings" do
            command.call
            election.reload

            expect(election.census_manifest).to eq("token_csv")
            expect(election.census_settings["fields"]).to eq(%w(name email))
            expect(election.census_settings["identifiers"]).to eq(%w(email))
            expect(election.census_settings["columns"]).to eq(
              [{ "header" => "Nombre", "field" => "name" }, { "header" => "Correo", "field" => "email" }]
            )
            expect(election.census_settings["file"]["name"]).to eq("people.csv")
            expect(election.census_settings["file"]["rows"]).to eq(2)
            expect(election.census_settings["file"]["imported_at"]).to be_present
          end

          it "replaces whoever was already on the list" do
            previous = Decidim::Elections::Voter.create!(election:, data: { "name" => "Someone else" })

            command.call

            expect(Decidim::Elections::Voter.exists?(previous.id)).to be(false)
            expect(election.voters.count).to eq(2)
          end

          it "purges the uploaded blob" do
            expect { command.call }.to have_enqueued_job(ActiveStorage::PurgeJob)
          end

          context "when the census was already a file census with different identifiers stored" do
            let(:election) { create(:election, census_manifest: "token_csv", census_settings: { "identifiers" => %w(phone) }) }

            it "replaces them with whatever was chosen for this import, rather than merging" do
              command.call

              expect(election.reload.census_settings["identifiers"]).to eq(%w(email))
            end
          end

          context "when the election opted in to Vocdoni" do
            before { Vocdoni::Process.create!(election:, state: "pending") }

            it "queues a fresh census pre-flight" do
              expect { command.call }.to have_enqueued_job(Vocdoni::PreflightCensusJob).with(election.id)

              expect(Vocdoni::Process.find_by(decidim_election_id: election.id)).to be_census_validation_pending
            end
          end

          context "when the file has an example row identical to the template's" do
            let(:columns) { { "0" => "name" } }
            let(:identifiers) { %w(name) }
            let(:content) do
              <<~CSV
                Nombre
                Ada
                Rosalind
              CSV
            end

            it "skips the example row without counting it as a person" do
              expect { command.call }.to broadcast(:ok, 1)

              expect(election.voters.count).to eq(1)
              expect(election.voters.first.data["name"]).to eq("Rosalind")
            end
          end

          context "when the file holds nothing but the template's example line" do
            let(:columns) { { "0" => "name", "1" => "email" } }
            let(:content) do
              <<~CSV
                Nombre,Correo
                Ada,ada@example.org
              CSV
            end

            it "says there is nobody to import rather than reporting lines to fix" do
              outcome = nil
              expect do
                described_class.call(form, election, user) { on(:no_rows) { |result| outcome = result } }
              end.not_to(change { election.voters.count })

              expect(outcome.skipped_examples).to eq(1)
              expect(outcome.failed_rows).to be_empty
            end
          end

          context "when the file has headings and no people under them" do
            let(:content) { "Nombre,Correo\n" }

            it "says there is nobody to import" do
              outcome = nil
              expect do
                described_class.call(form, election, user) { on(:no_rows) { |result| outcome = result } }
              end.not_to(change { election.voters.count })

              expect(outcome.skipped_examples).to eq(0)
            end
          end

          context "when one line is wrong" do
            let(:content) do
              <<~CSV
                Nombre,Correo
                Ada,ada@example.org
                Grace,not-an-email
              CSV
            end

            it "imports nothing at all and names the broken line" do
              outcome = nil
              expect do
                described_class.call(form, election, user) { on(:invalid_rows) { |result| outcome = result } }
              end.not_to(change { election.voters.count })

              expect(outcome).to be_failed
              expect(outcome.failed_rows.map(&:number)).to eq([3])
            end
          end
        end
      end
    end
  end
end
