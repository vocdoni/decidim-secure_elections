# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe VoterCredential do
        let(:election) { create(:election) }
        let(:organization) { election.organization }
        let(:user) { create(:user, :confirmed, organization:) }
        let(:voter) { create(:election_voter, election:) }

        def hmac(message)
          OpenSSL::HMAC.hexdigest("SHA256", described_class.secret, message)
        end

        describe ".for" do
          it "is the hex HMAC-SHA256 of the election and user ids" do
            expect(described_class.for(election, user)).to eq(hmac("#{election.id}:#{user.id}"))
            expect(described_class.for(election, user)).to match(/\A\h{64}\z/)
          end

          it "is a different credential in every election" do
            other = create(:election, component: election.component)

            expect(described_class.for(other, user)).not_to eq(described_class.for(election, user))
          end

          it "never gives a CSV row the credential of the user with the same id" do
            expect(described_class.for(election, voter)).to eq(hmac("#{election.id}:voter:#{voter.id}"))
            expect(described_class.for(election, voter)).not_to eq(hmac("#{election.id}:#{voter.id}"))
          end

          it "is nil for anything that is not a census entry" do
            expect(described_class.for(election, nil)).to be_nil
            expect(described_class.for(election, organization)).to be_nil
          end
        end

        describe ".secret" do
          it "is derived from secret_key_base with the dedicated salt" do
            expect(described_class.secret).to eq(Rails.application.key_generator.generate_key(described_class::SALT, 32))
            expect(described_class.secret).not_to eq(Rails.application.secret_key_base)
          end

          context "when VOCDONI_CREDENTIAL_SECRET is set" do
            around do |example|
              previous = ENV.fetch("VOCDONI_CREDENTIAL_SECRET", nil)
              ENV["VOCDONI_CREDENTIAL_SECRET"] = "an-explicit-secret"
              example.run
            ensure
              ENV["VOCDONI_CREDENTIAL_SECRET"] = previous
            end

            it "uses it" do
              expect(described_class.secret).to eq("an-explicit-secret")
              expect(described_class.for(election, user))
                .to eq(OpenSSL::HMAC.hexdigest("SHA256", "an-explicit-secret", "#{election.id}:#{user.id}"))
            end
          end
        end

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
        end
      end
    end
  end
end
