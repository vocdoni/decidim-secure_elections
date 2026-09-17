# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Vocdoni
      module Admin
        describe RemoveCensusFile do
          subject(:command) { described_class.new(election, user) }

          let(:organization) { create(:organization) }
          let(:user) { create(:user, :admin, :confirmed, organization:) }
          let(:election) do
            create(:election, census_manifest: "token_csv",
                              census_settings: { "fields" => %w(name), "identifiers" => %w(name) })
          end

          before { Decidim::Elections::Voter.create!(election:, data: { "name" => "Ada" }) }

          it "removes every voter and the census settings" do
            expect { command.call }.to broadcast(:ok)

            expect(election.voters.count).to eq(0)
            expect(election.reload.census_settings).to eq({})
          end

          it "leaves the census type alone, so another file can be uploaded" do
            command.call

            expect(election.reload.census_manifest).to eq("token_csv")
          end

          context "when the election can no longer be edited" do
            let(:election) do
              create(:election, :published, :ongoing, census_manifest: "token_csv",
                                                      census_settings: { "fields" => %w(name) })
            end

            it "is refused, and nothing changes" do
              expect { command.call }.to broadcast(:invalid)

              expect(election.voters.count).to eq(1)
              expect(election.reload.census_settings).not_to eq({})
            end
          end
        end
      end
    end
  end
end
