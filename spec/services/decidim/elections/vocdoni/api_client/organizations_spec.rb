# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    describe ApiClient::Organizations do
      subject(:organizations) { client.organizations }

      let(:client) { ApiClient.new }
      let(:api_url) { "https://saas-api-stg.vocdoni.net" }
      let(:api_key) { "vsk_0123456789abcdef" }
      let(:org_address) { "0x0000000000000000000000000000000000000001" }
      let(:json_headers) { { "Content-Type" => "application/json" } }

      def vocdoni_fixture(name)
        Decidim::Elections::Vocdoni::Engine.root.join("spec", "fixtures", "vocdoni", "#{name}.json").read
      end

      before do
        allow(Decidim::Elections::Vocdoni).to receive_messages(api_url:, api_key:, org_address:)
      end

      describe "#create_managed" do
        it "creates the managed organization and returns its address" do
          request = stub_request(:post, "#{api_url}/integrator/organizations")
                    .with(body: {
                            "name" => "Decidim Barcelona",
                            "type" => "association",
                            "website" => "https://example.org",
                            "country" => "ES",
                            "timezone" => "Europe/Madrid"
                          })
                    .to_return(status: 200, body: vocdoni_fixture("organization_created"), headers: json_headers)

          organization = organizations.create_managed(
            name: "Decidim Barcelona",
            type: :association,
            website: "https://example.org",
            country: "ES",
            timezone: "Europe/Madrid"
          )

          expect(organization["address"]).to eq(org_address)
          expect(request).to have_been_requested
        end

        it "omits the optional fields that were not given" do
          request = stub_request(:post, "#{api_url}/integrator/organizations")
                    .with(body: { "name" => "Decidim Barcelona", "type" => "association" })
                    .to_return(status: 200, body: vocdoni_fixture("organization_created"), headers: json_headers)

          organizations.create_managed(name: "Decidim Barcelona", type: "association")

          expect(request).to have_been_requested
        end
      end

      describe "#add_members" do
        let(:members) do
          [
            { memberNumber: "1001", name: "Alice", surname: "Doe", email: nil },
            { "memberNumber" => "1002", "name" => "Bob" }
          ]
        end

        it "wraps the members and drops nil attributes" do
          request = stub_request(:post, "#{api_url}/organizations/#{org_address}/members")
                    .with(body: {
                            "members" => [
                              { "memberNumber" => "1001", "name" => "Alice", "surname" => "Doe" },
                              { "memberNumber" => "1002", "name" => "Bob" }
                            ]
                          })
                    .to_return(status: 200, body: vocdoni_fixture("members_added"), headers: json_headers)

          expect(organizations.add_members(org_address, members)).to eq("added" => 2, "errors" => [])
          expect(request).to have_been_requested
        end

        it "can ask for the asynchronous path" do
          request = stub_request(:post, "#{api_url}/organizations/#{org_address}/members")
                    .with(query: { "async" => "true" })
                    .to_return(status: 200, body: vocdoni_fixture("members_added"), headers: json_headers)

          organizations.add_members(org_address, members, async: true)

          expect(request).to have_been_requested
        end

        it "hands the job id back so the caller can wait for the import" do
          stub_request(:post, "#{api_url}/organizations/#{org_address}/members")
            .to_return(status: 200, body: vocdoni_fixture("members_added_async"), headers: json_headers)

          expect(organizations.add_members(org_address, members)["jobId"]).to eq("6885f1a3c1a4e2f0b1d33a30")
        end
      end

      describe "#members" do
        it "reads the memberbase, which is the only source of member ids" do
          request = stub_request(:get, "#{api_url}/organizations/#{org_address}/members")
                    .with(headers: { "Authorization" => "Bearer #{api_key}" })
                    .to_return(status: 200, body: vocdoni_fixture("organization_members"), headers: json_headers)

          members = organizations.members(org_address)

          expect(members["members"].map { |member| member["id"] }).to eq(%w(6a677022622d94e7c9a19301 6a677022622d94e7c9a19302))
          expect(members.dig("pagination", "nextPage")).to be_nil
          expect(request).to have_been_requested
        end

        it "asks for a given page" do
          request = stub_request(:get, "#{api_url}/organizations/#{org_address}/members")
                    .with(query: { "page" => "2" })
                    .to_return(status: 200, body: vocdoni_fixture("organization_members"), headers: json_headers)

          organizations.members(org_address, page: 2)

          expect(request).to have_been_requested
        end
      end

      describe "#create_group" do
        it "creates the election's member group and returns only its id" do
          request = stub_request(:post, "#{api_url}/organizations/#{org_address}/groups")
                    .with(body: {
                            "title" => "Board election 2026 (BCN-VOCD-2026-01)",
                            "description" => "Census of the Decidim election BCN-VOCD-2026-01.",
                            "memberIds" => %w(6a677022622d94e7c9a19301 6a677022622d94e7c9a19302)
                          })
                    .to_return(status: 200, body: vocdoni_fixture("group_created"), headers: json_headers)

          group = organizations.create_group(
            org_address,
            title: "Board election 2026 (BCN-VOCD-2026-01)",
            description: "Census of the Decidim election BCN-VOCD-2026-01.",
            member_ids: %w(6a677022622d94e7c9a19301 6a677022622d94e7c9a19302)
          )

          expect(group["id"]).to eq("6a677022622d94e7c9a1929a")
          expect(request).to have_been_requested
        end

        it "omits a description that was not given" do
          request = stub_request(:post, "#{api_url}/organizations/#{org_address}/groups")
                    .with(body: { "title" => "Board election 2026", "memberIds" => ["6a677022622d94e7c9a19301"] })
                    .to_return(status: 200, body: vocdoni_fixture("group_created"), headers: json_headers)

          organizations.create_group(org_address, title: "Board election 2026", member_ids: ["6a677022622d94e7c9a19301"])

          expect(request).to have_been_requested
        end
      end

      describe "#validate_group" do
        let(:group_id) { "6a677022622d94e7c9a1929a" }
        let(:validate_url) { "#{api_url}/organizations/#{org_address}/groups/#{group_id}/validate" }

        it "sends the fields the census will authenticate on" do
          request = stub_request(:post, validate_url)
                    .with(body: { "authFields" => ["memberNumber"], "twoFaFields" => ["email"] })
                    .to_return(status: 200, body: "")

          organizations.validate_group(org_address, group_id, auth_fields: ["memberNumber"], two_fa_fields: ["email"])

          expect(request).to have_been_requested
        end

        it "answers an empty hash to the empty body a success returns" do
          stub_request(:post, validate_url).to_return(status: 200, body: "")

          expect(organizations.validate_group(org_address, group_id, auth_fields: ["memberNumber"])).to eq({})
        end

        it "drops an empty two-factor list, which is how an auth-only census is expressed" do
          request = stub_request(:post, validate_url)
                    .with(body: { "authFields" => ["memberNumber"] })
                    .to_return(status: 200, body: "")

          organizations.validate_group(org_address, group_id, auth_fields: ["memberNumber"], two_fa_fields: [])

          expect(request).to have_been_requested
        end

        context "when members lack a requested field" do
          before do
            stub_request(:post, validate_url)
              .to_return(status: 400, body: vocdoni_fixture("group_validation_failed"), headers: json_headers)
          end

          it "raises rather than letting an unusable census reach the chain" do
            expect { organizations.validate_group(org_address, group_id, auth_fields: ["nationalId"]) }
              .to raise_error(Decidim::Elections::Vocdoni::ApiError) do |error|
                expect(error.status).to eq(400)
                expect(error.code).to eq(40_037)
                expect(error.message).to include("invalid data provided")
              end
          end

          it "keeps the offending member ids intact on the error" do
            expect { organizations.validate_group(org_address, group_id, auth_fields: ["nationalId"]) }
              .to raise_error(Decidim::Elections::Vocdoni::ApiError) do |error|
                expect(error.body.dig("data", "missingData"))
                  .to eq(%w(6a677022622d94e7c9a19301 6a677022622d94e7c9a19302))
              end
          end
        end
      end

      describe "#groups" do
        it "lists the member groups, including the auto group used as a census" do
          request = stub_request(:get, "#{api_url}/organizations/#{org_address}/groups")
                    .with(headers: { "Authorization" => "Bearer #{api_key}" })
                    .to_return(status: 200, body: vocdoni_fixture("organization_groups"), headers: json_headers)

          groups = organizations.groups(org_address)

          expect(groups["groups"].map { |group| group["id"] }).to eq(%w(000000000000000000000001 6a677022622d94e7c9a1928f))
          expect(groups["groups"].first["isAutoGroup"]).to be(true)
          expect(request).to have_been_requested
        end
      end
    end
  end
end
end
