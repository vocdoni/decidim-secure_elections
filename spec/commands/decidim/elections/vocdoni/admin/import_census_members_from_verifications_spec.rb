# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    module Admin
      describe ImportCensusMembersFromVerifications do
        subject(:command) { described_class.new(form, election, current_user) }

        let(:organization) { create(:organization, available_authorizations: ["dummy_authorization_handler"]) }
        let(:current_user) { create(:user, :admin, :confirmed, organization:) }
        let(:election) { create(:vocdoni_election, census_two_fa_fields: ["email"]) }
        let(:context) { { current_organization: organization, current_user:, election: } }

        let(:form) do
          CensusVerificationsForm
            .from_params(census_verifications: { authorization_handler: "dummy_authorization_handler", replace: })
            .with_context(context)
        end
        let(:replace) { false }

        let!(:verified) { create_list(:user, 2, :confirmed, organization:) }

        before do
          verified.each { |user| create(:authorization, :granted, name: "dummy_authorization_handler", user:) }
        end

        it "brings the verified participants into the census" do
          expect { command.call }.to broadcast(:ok)

          expect(election.census_members.pluck(:email)).to match_array(verified.map(&:email))
          expect(election.reload.census_size).to eq(2)
        end

        # A verification that is still pending is not an entitlement to vote.
        context "when an authorization has not been granted" do
          let!(:pending) { create(:user, :confirmed, organization:) }

          before { create(:authorization, :pending, name: "dummy_authorization_handler", user: pending) }

          it "leaves them out" do
            command.call

            expect(election.census_members.count).to eq(2)
          end
        end

        # Running it twice is how an admin catches up with new verifications;
        # it must not double anybody up.
        it "adds only the people who are not in the census yet" do
          command.call
          expect { described_class.new(form, election, current_user).call }.not_to change(election.census_members, :count)
        end

        context "when nobody holds the verification" do
          before { Decidim::Authorization.destroy_all }

          it { expect { command.call }.to broadcast(:invalid) }
        end

        context "when the verification is not switched on for the organization" do
          let(:organization) { create(:organization, available_authorizations: []) }

          it { expect { command.call }.to broadcast(:invalid) }
        end

        context "when the election is already on chain" do
          before { election.update!(vocdoni_process_id: "6885f0c2c1a4e2f0b1d33a01") }

          it "refuses to change who may vote" do
            expect { command.call }.to broadcast(:invalid)
            expect(election.census_members.count).to eq(0)
          end
        end
      end
    end
  end
end
end
