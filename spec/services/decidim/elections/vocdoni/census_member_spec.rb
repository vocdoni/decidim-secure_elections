# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe CensusMember do
        let(:election) { create(:election) }
        let(:organization) { election.organization }
        let(:user) { create(:user, :confirmed, organization:) }
        let(:voter) { create(:election_voter, election:) }

        describe ".subject_for" do
          it "finds the user of an internal_users voter_uid" do
            expect(described_class.subject_for(election, user.to_global_id.to_s)).to eq(user)
          end

          it "finds the CSV row of a token_csv voter_uid" do
            expect(described_class.subject_for(election, voter.to_global_id.to_s)).to eq(voter)
          end

          it "refuses a user of another organization" do
            stranger = create(:user, :confirmed)

            expect(described_class.subject_for(election, stranger.to_global_id.to_s)).to be_nil
          end

          it "refuses a CSV row of another election" do
            foreign = create(:election_voter)

            expect(described_class.subject_for(election, foreign.to_global_id.to_s)).to be_nil
          end

          it "is nil without a voter_uid or for a record that does not exist" do
            expect(described_class.subject_for(election, nil)).to be_nil
            expect(described_class.subject_for(election, "gid://#{GlobalID.app}/Decidim::User/0")).to be_nil
          end

          it "is nil for a voter_uid of any other model, known or not" do
            expect(described_class.subject_for(election, organization.to_global_id.to_s)).to be_nil
            expect(described_class.subject_for(election, "gid://#{GlobalID.app}/No::Such::Model/1")).to be_nil
            expect(described_class.subject_for(election, "gid://#{GlobalID.app}/Kernel/1")).to be_nil
          end
        end

        describe ".phone" do
          it "reads a CSV row's phone column" do
            row = create(:election_voter, election:, data: { "email" => "a@example.org", "phone" => "+34600000002" })

            expect(described_class.phone(row)).to eq("+34600000002")
          end

          it "picks the oldest granted authorization's phone" do
            create(:authorization, :granted, user:, organization:, name: "dummy_authorization_handler",
                                             metadata: { "phone_number" => "+34600000001" })
            create(:authorization, :granted, user:, organization:, name: "another_dummy_authorization_handler",
                                             metadata: { "phone_number" => "+34600000009" })

            expect(described_class.phone(user)).to eq("+34600000001")
          end

          it "is nil when the voter has none" do
            expect(described_class.phone(user)).to be_nil
          end
        end
      end
    end
  end
end
