# frozen_string_literal: true

require "spec_helper"

module Decidim
  module SecureElections
    describe CensusMember do
      subject(:member) { build(:vocdoni_census_member, election:) }

      let(:election) { create(:vocdoni_election) }

      it { is_expected.to be_valid }

      describe "field mapping" do
        # The API speaks camelCase and the database speaks snake_case. Every
        # part of the census — the credential picker, the CSV template, the
        # importer — depends on this staying in step.
        it "maps every upstream field to a column" do
          expect(described_class::FIELDS.map { |field| described_class.attribute_for(field) }).to all(be_present)
        end

        it "excludes the two-factor fields and voting power from the credentials" do
          expect(described_class::CREDENTIAL_FIELDS).to match_array(%w(name surname memberNumber nationalId birthDate))
        end

        it "reads a value by its upstream name" do
          member.member_number = "000123"

          expect(member.value_for("memberNumber")).to eq("000123")
        end
      end

      describe "validations" do
        it "refuses a row with nothing in it" do
          empty = build(:vocdoni_census_member, election:, name: nil, surname: nil, email: nil, member_number: nil)

          expect(empty).not_to be_valid
        end

        # Regression: production had two voters carrying only name+surname; each
        # retry of the publish job pushed them as fresh records upstream and left
        # zombie member ids behind. The memberbase can only match on
        # `IDENTITY_FIELDS`, so a name-only row must not be saved.
        it "refuses a row with only a name and surname" do
          named = build(:vocdoni_census_member, election:, name: "Ada", surname: "Lovelace",
                                                email: nil, phone: nil, member_number: nil, national_id: nil)

          expect(named).not_to be_valid
          expect(named.errors[:base]).to include(a_string_matching(/member number|national id|email|phone/i))
        end

        it "accepts a row with just an email" do
          email_only = build(:vocdoni_census_member, election:, name: nil, surname: nil,
                                                     email: "ada@example.org", member_number: nil)

          expect(email_only).to be_valid
        end

        it "refuses an unusable email" do
          member.email = "not-an-email"

          expect(member).not_to be_valid
        end

        it "refuses a voting power of zero" do
          member.weight = 0

          expect(member).not_to be_valid
        end

        it "normalizes blank strings to nil so they read as missing" do
          member.update!(national_id: "   ")

          expect(member.reload.national_id).to be_nil
        end
      end

      describe "#missing_fields" do
        let(:election) { create(:vocdoni_election, census_auth_fields: ["memberNumber"], census_two_fa_fields: ["email"]) }

        it "is empty when the member has everything the census needs" do
          expect(member.missing_fields).to be_empty
        end

        # ARCHITECTURE §4c-bis: with 2FA the contact value is part of the voter's
        # identity, not just a delivery address, so a member without it cannot
        # vote at all.
        it "reports the two-factor contact as missing" do
          member.email = nil

          expect(member.missing_fields).to eq(["email"])
        end

        context "when the voter chooses the channel" do
          let(:election) { create(:vocdoni_election, census_auth_fields: [], census_two_fa_fields: %w(email phone)) }

          it "accepts either contact" do
            member.email = nil
            member.phone = "+34600000000"

            expect(member.missing_fields).to be_empty
          end

          it "reports both when neither is present" do
            member.email = nil
            member.phone = nil

            expect(member.missing_fields).to match_array(%w(email phone))
          end
        end
      end

      describe "#to_api_member" do
        it "uses the upstream field names and drops what is not filled in" do
          member.assign_attributes(name: "Ada", surname: "Lovelace", email: "ada@example.org",
                                   member_number: "000123", national_id: nil, birth_date: Date.new(1990, 1, 1))

          payload = member.to_api_member

          expect(payload).to include("name" => "Ada", "memberNumber" => "000123", "birthDate" => "1990-01-01")
          expect(payload).not_to have_key("nationalId")
        end

        it "always sends voting power, since zero is meaningful and blank is not" do
          expect(member.to_api_member).to have_key("weight")
        end
      end
    end
  end
end
