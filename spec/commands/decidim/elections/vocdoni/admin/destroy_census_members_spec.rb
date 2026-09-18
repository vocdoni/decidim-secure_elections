# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    module Admin
      describe DestroyCensusMembers do
        subject(:command) { described_class.new(election, current_user) }

        let(:organization) { create(:organization) }
        let(:current_user) { create(:user, :admin, :confirmed, organization:) }
        let(:election) { create(:vocdoni_election) }

        before { create_list(:vocdoni_census_member, 3, election:) }

        it "empties the census and says how many people went" do
          expect { command.call }.to broadcast(:ok)

          expect(election.census_members.count).to eq(0)
          expect(election.reload.census_size).to eq(0)
        end

        context "when the census is already empty" do
          before { election.census_members.destroy_all }

          it { expect { command.call }.to broadcast(:invalid) }
        end

        # The process on chain keeps the census it was published with, so
        # clearing the local copy would only make Decidim lie about who may
        # vote.
        context "when the election is already on chain" do
          before { election.update!(vocdoni_process_id: "6885f0c2c1a4e2f0b1d33a01") }

          it "refuses" do
            expect { command.call }.to broadcast(:invalid)
            expect(election.census_members.count).to eq(3)
          end
        end
      end
    end
  end
end
end
