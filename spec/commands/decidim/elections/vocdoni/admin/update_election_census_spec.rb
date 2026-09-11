# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    module Admin
      describe UpdateElectionCensus do
        subject(:command) { described_class.new(form, election) }

        let(:organization) { create(:organization) }
        let(:current_user) { create(:user, :admin, :confirmed, organization:) }
        let(:election) { create(:vocdoni_election) }
        let(:context) { { current_organization: organization, current_user:, election: } }

        let(:form) do
          CensusForm.from_params(
            census: {
              credentials: ["memberNumber", ""],
              two_factor_method: "email",
              weighted: true
            }
          ).with_context(context)
        end

        it "stores how a voter authenticates" do
          expect { command.call }.to broadcast(:ok)

          election.reload
          expect(election.census_auth_fields).to eq(["memberNumber"])
          expect(election.census_two_fa_fields).to eq(["email"])
          expect(election).to be_weighted
        end

        # The census contract in one assertion: no member group id is written, because
        # none is ever asked for. The publish job creates the group.
        it "never writes a Vocdoni identifier" do
          command.call

          expect(election.reload.census_group_id).to be_nil
        end

        it "keeps the turnout denominator in step with the census" do
          create_list(:vocdoni_census_member, 2, election:)

          command.call

          expect(election.reload.census_size).to eq(2)
        end

        context "when the election is already on chain" do
          before { election.update!(vocdoni_process_id: "6885f0c2c1a4e2f0b1d33a01") }

          it "refuses to change who may vote" do
            expect { command.call }.to broadcast(:invalid)
            expect(election.reload.census_auth_fields).to eq([])
          end
        end
      end
    end
  end
end
end
