# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe PublishElectionJob do
        subject(:job) do
          described_class.new.tap { |j| j.instance_variable_set(:@election, election) }
        end

        # Exercises the roster path in isolation — `voter_payloads` is the
        # single point where the manifest determines what gets pushed to the
        # SaaS memberbase. The rest of the job (client calls, sidecar writes,
        # step retries) is covered by end-to-end specs elsewhere.
        describe "#voter_payloads" do
          let(:payloads) { job.send(:voter_payloads) }

          context "when the manifest is token_csv" do
            let(:election) { create(:election, :with_token_csv_census) }

            it "pushes one member per uploaded CSV row" do
              tokens = election.voters.pluck(:data).pluck("token")
              expect(payloads.pluck("memberNumber")).to match_array(tokens)
            end

            it "uses the CSV token as the memberNumber and the CSV email as email" do
              expected = election.voters.map do |v|
                { "memberNumber" => v.data["token"], "email" => v.data["email"] }
              end
              expect(payloads).to match_array(expected)
            end

            it "ignores Decidim::User rows entirely" do
              create_list(:user, 3, organization: election.organization)
              tokens = election.voters.pluck(:data).pluck("token")
              expect(payloads.pluck("memberNumber")).to match_array(tokens)
            end

            it "drops rows with a blank token" do
              election.voters.create!(data: { "email" => "noone@example.org", "token" => "" })
              expect(election.voters.count).to eq(4)
              expect(payloads.size).to eq(3)
              expect(payloads.pluck("memberNumber")).to all(be_present)
            end

            it "dedupes locally when two CSV rows share a token" do
              election.voters.create!(data: { "email" => "dup1@example.org", "token" => "shared" })
              election.voters.create!(data: { "email" => "dup2@example.org", "token" => "shared" })
              expect(payloads.pluck("memberNumber").tally["shared"]).to eq(1)
            end
          end

          context "when the manifest is internal_users" do
            let(:organization) { create(:organization) }
            let(:election) { create(:election, :with_internal_users_census, component: create(:elections_component, organization:)) }

            before do
              create_list(:user, 3, organization:)
            end

            it "pushes Decidim::User rows keyed by user id" do
              expected_ids = Decidim::User.where(organization:).order(id: :asc).pluck(:id).map(&:to_s)
              expect(payloads.pluck("memberNumber")).to match_array(expected_ids)
            end

            it "ignores any Decidim::Elections::Voter rows attached to the election" do
              create(:election_voter, election:, data: { email: "csv@example.org", token: "ignored" })
              expect(payloads.pluck("memberNumber")).not_to include("ignored")
            end

            it "caps the roster at DEMO_ROSTER_LIMIT" do
              stub_const("Decidim::Elections::Vocdoni::PublishElectionJob::DEMO_ROSTER_LIMIT", 2)
              expect(payloads.size).to eq(2)
            end
          end
        end
      end
    end
  end
end
