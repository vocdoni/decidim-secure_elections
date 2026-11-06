# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe VotingBackend do
        describe ".booth_config" do
          let(:election) { create(:election, census_manifest:) }
          let(:census_manifest) { "internal_users" }
          let(:two_fa_fields) { ["email"] }
          let!(:vocdoni_process) do
            create(:vocdoni_process, :published, election:, metadata: { "settings" => { "twofa_fields" => two_fa_fields } })
          end
          let(:user) { create(:user, :confirmed, organization: election.organization, email: "ada@example.org") }

          def config_for(voter_uid)
            described_class.booth_config(election, voter_uid:)
          end

          it "hands the voter the credential the publish job pushed" do
            config = config_for(user.to_global_id.to_s)

            expect(config[:credentials]).to eq(memberNumber: VoterCredential.for(election, user))
            expect(config[:credentials][:memberNumber]).not_to eq(user.id.to_s)
            expect(config[:contact]).to eq(email: "ada@example.org", masked: "a•••@example.org")
          end

          it "matches the member the publish job builds for the same voter" do
            member = CensusMember.payload(election, user, two_fa_fields:)

            expect(config_for(user.to_global_id.to_s)[:credentials][:memberNumber]).to eq(member["memberNumber"])
          end

          it "gives no credential without a census voter" do
            expect(config_for(nil)[:credentials]).to eq(memberNumber: nil)
            expect(config_for(create(:user, :confirmed).to_global_id.to_s)[:credentials]).to eq(memberNumber: nil)
          end

          context "with a token_csv census" do
            let(:census_manifest) { "token_csv" }
            let(:two_fa_fields) { %w(email phone) }
            let(:voter) do
              create(:election_voter, election:, data: { "email" => "bob@example.org", "token" => "S3CRET", "phone" => "600000002" })
            end

            it "derives the credential from the CSV row and never exposes its token" do
              config = config_for(voter.to_global_id.to_s)

              expect(config[:credentials]).to eq(memberNumber: VoterCredential.for(election, voter))
              expect(config[:contact]).to eq(email: "bob@example.org", phone: "600000002", masked: "b•••@example.org")
              expect(config.to_json).not_to include("S3CRET")
            end

            it "matches the member the publish job builds for the same row" do
              member = CensusMember.payload(election, voter, two_fa_fields:)

              expect(config_for(voter.to_global_id.to_s)[:credentials][:memberNumber]).to eq(member["memberNumber"])
              expect(config_for(voter.to_global_id.to_s)[:contact][:phone]).to eq(member["phone"])
            end
          end
        end
      end
    end
  end
end
