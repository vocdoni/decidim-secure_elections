# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe ApiClient::Elections do
        subject(:elections) { ApiClient.new.elections }

        let(:api_url) { "https://saas-api.example.org" }
        let(:process_id) { "6885f0c2c1a4e2f0b1d33a01" }
        let(:json_headers) { { "Content-Type" => "application/json" } }
        let(:voter_id) { "0x#{"ab" * 32}" }

        it "rotates the attestation signer" do
          stub = stub_request(:put, "#{api_url}/processes/#{process_id}/attestation-signer")
                 .with(body: { signer: "0x00000000000000000000000000000000000000aa" })
                 .to_return(status: 200, body: { signer: "0x00000000000000000000000000000000000000aa" }.to_json, headers: json_headers)

          elections.rotate_attestation_signer(process_id, "0x00000000000000000000000000000000000000aa")
          expect(stub).to have_been_requested
        end

        it "grows the census size" do
          stub = stub_request(:put, "#{api_url}/processes/#{process_id}/census/size")
                 .with(body: { size: 24 })
                 .to_return(status: 202, body: { size: 24, jobId: "j1" }.to_json, headers: json_headers)

          expect(elections.grow_census_size(process_id, 24).to_h).to include("jobId" => "j1")
          expect(stub).to have_been_requested
        end

        it "looks an attested voter up by voterId" do
          stub_request(:get, "#{api_url}/processes/#{process_id}/participants")
            .with(query: { field: "voterId", value: "ab" * 32 })
            .to_return(status: 200, body: { participants: [{ voterId: "ab" * 32, questions: [] }] }.to_json, headers: json_headers)

          expect(elections.attested_participant(process_id, voter_id)).to include("voterId" => "ab" * 32)
        end

        it "answers nil for a voter the SaaS signed nothing for" do
          stub_request(:get, "#{api_url}/processes/#{process_id}/participants")
            .with(query: { field: "voterId", value: "ab" * 32 })
            .to_return(status: 200, body: { participants: [] }.to_json, headers: json_headers)

          expect(elections.attested_participant(process_id, voter_id)).to be_nil
        end

        it "reads the published attestations without the API key" do
          stub = stub_request(:get, "#{api_url}/processes/#{process_id}/attestations")
                 .with(query: { page: 1, limit: 100 })
                 .to_return(status: 200, body: { attestations: [], pagination: { totalItems: 0 } }.to_json, headers: json_headers)

          elections.attestations(process_id)
          expect(stub.with { |request| !request.headers.has_key?("Authorization") }).to have_been_requested
        end
      end
    end
  end
end
