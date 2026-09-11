# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    module Admin
      describe UpdateCensusMembers do
        subject(:command) { described_class.new(form, election, current_user) }

        let(:organization) { create(:organization) }
        let(:current_user) { create(:user, :admin, :confirmed, organization:) }
        let(:election) { create(:vocdoni_election, census_auth_fields: ["memberNumber"]) }
        let(:context) { { current_organization: organization, current_user:, election: } }
        let!(:existing) { create(:vocdoni_census_member, election:, name: "Ada", member_number: "000123") }

        let(:form) { CensusMembersForm.from_params(census: { members: }).with_context(context) }

        let(:members) do
          {
            "0" => { id: existing.id, name: "Augusta", surname: existing.surname, member_number: "000123" },
            "1" => { name: "Grace", surname: "Hopper", member_number: "000124" }
          }
        end

        it "creates, updates and counts in one go" do
          expect { command.call }.to broadcast(:ok)

          expect(election.census_members.count).to eq(2)
          expect(existing.reload.name).to eq("Augusta")
          expect(election.reload.census_size).to eq(2)
        end

        context "when a row is removed" do
          let(:members) do
            { "0" => { id: existing.id, name: existing.name, deleted: "1" } }
          end

          it "deletes it" do
            expect { command.call }.to broadcast(:ok)

            expect(election.census_members.count).to eq(0)
            expect(election.reload.census_size).to eq(0)
          end
        end

        context "when a cell is cleared" do
          let(:members) do
            { "0" => { id: existing.id, name: "", surname: "Lovelace", member_number: "000123" } }
          end

          it "actually clears it" do
            command.call

            expect(existing.reload.name).to be_nil
          end
        end

        # All or nothing: a half-saved table would show the admin a census that
        # no longer matches the database.
        context "when one row is invalid" do
          let(:members) do
            {
              "0" => { id: existing.id, name: "Augusta", member_number: "000123" },
              "1" => { name: "Grace", member_number: "" }
            }
          end

          it "saves nothing" do
            expect { command.call }.to broadcast(:invalid)

            expect(existing.reload.name).to eq("Ada")
            expect(election.census_members.count).to eq(1)
          end
        end

        context "when the election is already on chain" do
          before { election.update!(vocdoni_process_id: "6885f0c2c1a4e2f0b1d33a01") }

          it "refuses to change who may vote" do
            expect { command.call }.to broadcast(:invalid)
            expect(election.census_members.count).to eq(1)
          end
        end
      end
    end
  end
end
end
