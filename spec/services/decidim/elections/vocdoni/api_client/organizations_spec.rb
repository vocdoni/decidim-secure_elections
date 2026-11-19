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
      end
    end
  end
end
