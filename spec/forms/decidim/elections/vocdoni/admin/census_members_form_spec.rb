# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    module Admin
      describe CensusMembersForm do
        subject(:form) { described_class.from_params(attributes).with_context(context) }

        let(:organization) { create(:organization) }
        let(:election) { create(:vocdoni_election, census_auth_fields: ["memberNumber"]) }
        let(:context) { { current_organization: organization, election: } }

        let(:attributes) do
          {
            census: {
              members: {
                "0" => { name: "Ada", surname: "Lovelace", member_number: "000123" },
                "1" => { name: "Grace", surname: "Hopper", member_number: "000124" }
              }
            }
          }
        end

        it { is_expected.to be_valid }

        # A spare row nobody typed into is not a mistake; complaining about it
        # would make the "add a row" button unusable.
        context "when a new row is left completely empty" do
          before { attributes[:census][:members]["2"] = { name: "", surname: "", member_number: "" } }

          it { is_expected.to be_valid }

          it "does not try to save it" do
            expect(form.kept_members.size).to eq(2)
          end
        end

        context "when a row is missing what the election authenticates on" do
          before { attributes[:census][:members]["1"][:member_number] = "" }

          it { is_expected.to be_invalid }

          it "reports the error on the offending row" do
            form.valid?

            expect(form.members.second.errors[:member_number]).not_to be_empty
          end
        end

        # Two rows with the same member number are two ballots for one person.
        context "when two rows share the value the census matches on" do
          before { attributes[:census][:members]["1"][:member_number] = "000123" }

          it { is_expected.to be_invalid }

          it "flags both rows" do
            form.valid?

            expect(form.members.first.errors[:member_number]).not_to be_empty
            expect(form.members.second.errors[:member_number]).not_to be_empty
          end
        end

        context "when a duplicate is on a field the census does not use" do
          let(:attributes) do
            {
              census: {
                members: {
                  "0" => { name: "Ada", member_number: "000123", phone: "+34600000000" },
                  "1" => { name: "Grace", member_number: "000124", phone: "+34600000000" }
                }
              }
            }
          end

          it { is_expected.to be_valid }
        end

        describe "#deleted_ids" do
          let(:member) { create(:vocdoni_census_member, election:) }

          before do
            attributes[:census][:members]["2"] = { id: member.id, name: member.name, deleted: "1" }
          end

          it "collects the rows the admin removed" do
            expect(form.deleted_ids).to eq([member.id])
          end

          # A row on its way out does not have to be valid.
          it { is_expected.to be_valid }
        end
      end
    end
  end
end
end
