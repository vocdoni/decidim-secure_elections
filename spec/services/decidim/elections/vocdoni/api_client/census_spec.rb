# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    describe ApiClient::Census do
      subject(:census) { client.census }

      let(:client) { ApiClient.new }
      let(:api_url) { "https://saas-api-stg.vocdoni.net" }
      let(:api_key) { "vsk_0123456789abcdef" }
      let(:org_address) { "0x0000000000000000000000000000000000000001" }
      let(:group_id) { "000000000000000000000001" }
      let(:census_id) { "6885f0c2c1a4e2f0b1d33b01" }
      let(:member_ids) { %w(6a677022622d94e7c9a19301 6a677022622d94e7c9a19302) }
      let(:json_headers) { { "Content-Type" => "application/json" } }

      def vocdoni_fixture(name)
        Decidim::Elections::Vocdoni::Engine.root.join("spec", "fixtures", "vocdoni", "#{name}.json").read
      end

      before do
        allow(Decidim::Elections::Vocdoni).to receive_messages(api_url:, api_key:, org_address:)
      end

      describe "#create" do
        it "creates an empty org-level census" do
          request = stub_request(:post, "#{api_url}/census")
                    .with(body: { "orgAddress" => org_address, "authFields" => ["memberNumber"] })
                    .to_return(status: 200, body: vocdoni_fixture("census_created"), headers: json_headers)

          expect(census.create(org_address, auth_fields: ["memberNumber"])).to eq("id" => census_id)
          expect(request).to have_been_requested
        end

        it "falls back to the configured organization" do
          request = stub_request(:post, "#{api_url}/census")
                    .with(body: { "orgAddress" => org_address })
                    .to_return(status: 200, body: vocdoni_fixture("census_created"), headers: json_headers)

          expect(census.create["id"]).to eq(census_id)
          expect(request).to have_been_requested
        end
      end

      describe "#get" do
        it "reads the census" do
          request = stub_request(:get, "#{api_url}/census/#{census_id}")
                    .to_return(status: 200, body: vocdoni_fixture("census"), headers: json_headers)

          expect(census.get(census_id)["censusId"]).to eq(census_id)
          expect(request).to have_been_requested
        end
      end

      describe "#add_participants" do
        it "adds existing members by id" do
          request = stub_request(:post, "#{api_url}/census/#{census_id}")
                    .with(body: { "memberIds" => member_ids })
                    .to_return(status: 200, body: vocdoni_fixture("members_added"), headers: json_headers)

          census.add_participants(census_id, member_ids)

          expect(request).to have_been_requested
        end
      end

      describe "#participants" do
        it "lists the member ids" do
          request = stub_request(:get, "#{api_url}/census/#{census_id}/participants")
                    .to_return(status: 200, body: vocdoni_fixture("census_participants"), headers: json_headers)

          expect(census.participants(census_id)["memberIds"]).to eq(member_ids)
          expect(request).to have_been_requested
        end
      end

      describe "#publish" do
        it "builds the Merkle census" do
          request = stub_request(:post, "#{api_url}/census/#{census_id}/publish")
                    .with(body: { "authFields" => ["memberNumber"], "weighted" => false })
                    .to_return(status: 200, body: vocdoni_fixture("census_published"), headers: json_headers)

          expect(census.publish(census_id, auth_fields: ["memberNumber"], weighted: false)["size"]).to eq(3)
          expect(request).to have_been_requested
        end
      end

      describe "#publish_group" do
        it "publishes an auth-only census out of a member group" do
          request = stub_request(:post, "#{api_url}/census/#{census_id}/group/#{group_id}/publish")
                    .with(body: { "authFields" => ["memberNumber"], "weighted" => false })
                    .to_return(status: 200, body: vocdoni_fixture("census_published"), headers: json_headers)

          published = census.publish_group(census_id, group_id, auth_fields: ["memberNumber"])

          expect(published).to include("root", "size", "uri")
          expect(published["size"]).to eq(3)
          expect(request).to have_been_requested
        end

        it "publishes a two-factor, weighted census" do
          request = stub_request(:post, "#{api_url}/census/#{census_id}/group/#{group_id}/publish")
                    .with(body: {
                            "authFields" => ["memberNumber"],
                            "twoFaFields" => ["email"],
                            "weighted" => true
                          })
                    .to_return(status: 200, body: vocdoni_fixture("census_published"), headers: json_headers)

          census.publish_group(census_id, group_id, auth_fields: ["memberNumber"], two_fa_fields: ["email"], weighted: true)

          expect(request).to have_been_requested
        end
      end
    end
  end
end
end
