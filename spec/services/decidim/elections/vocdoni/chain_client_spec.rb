# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe ChainClient do
        subject(:client) { described_class.new(api_url:) }

        let(:api_url) { "https://chain.example.org/v2" }
        let(:json_headers) { { "Content-Type" => "application/json" } }
        let(:election_id) { "c0ffee0000010000000000000000000000000000000000aa0400000000000001" }
        let(:nullifier) { SecureRandom.hex(32) }

        def captured_api_error
          yield
          raise "expected Decidim::Elections::Vocdoni::ApiError to be raised, but nothing was"
        rescue ApiError => e
          e
        end

        describe "#chain_info" do
          it "returns the chain info" do
            stub_request(:get, "#{api_url}/chain/info")
              .to_return(status: 200, body: { chainId: "vocdoni/DEV/36", height: 10 }.to_json, headers: json_headers)
            expect(client.chain_info).to include("chainId" => "vocdoni/DEV/36")
          end

          it "does not double the slash after a base URL that ends in one" do
            request = stub_request(:get, "#{api_url}/chain/info").to_return(status: 200, body: "{}", headers: json_headers)
            described_class.new(api_url: "#{api_url}/").chain_info
            expect(request).to have_been_requested
          end

          it "defaults to the configured chain API URL" do
            allow(Vocdoni).to receive(:chain_api_url).and_return(api_url)
            stub_request(:get, "#{api_url}/chain/info").to_return(status: 200, body: "{}", headers: json_headers)
            expect(described_class.new.chain_info).to eq({})
          end
        end

        describe "#election" do
          it "returns the on-chain election" do
            body = { electionId: election_id, census: { censusRoot: "02ab", maxCensusSize: 6 } }
            stub_request(:get, "#{api_url}/elections/#{election_id}")
              .to_return(status: 200, body: body.to_json, headers: json_headers)
            expect(client.election("0x#{election_id}").dig("census", "maxCensusSize")).to eq(6)
          end

          it "raises a transient error on a 404" do
            stub_request(:get, "#{api_url}/elections/#{election_id}").to_return(status: 404, body: "{}", headers: json_headers)
            error = captured_api_error { client.election(election_id) }
            expect(error.status).to eq(404)
            expect(error).to be_transient
          end

          it "refuses an id that is not hex" do
            expect { client.election("../chain/info") }.to raise_error(ArgumentError)
          end
        end

        describe "#vote" do
          it "returns the vote when the chain has it" do
            stub_request(:get, "#{api_url}/votes/#{nullifier}")
              .to_return(status: 200, body: { voteID: nullifier }.to_json, headers: json_headers)
            expect(client.vote(nullifier)).to include("voteID" => nullifier)
          end

          it "returns nil on a 404" do
            stub_request(:get, "#{api_url}/votes/#{nullifier}")
              .to_return(status: 404, body: { error: "vote not found", code: 4019 }.to_json, headers: json_headers)
            expect(client.vote(nullifier)).to be_nil
          end

          it "raises a transient error on a 500 without naming the nullifier" do
            stub_request(:get, "#{api_url}/votes/#{nullifier}").to_return(status: 500, body: "{}", headers: json_headers)
            error = captured_api_error { client.vote(nullifier) }
            expect(error).to be_transient
            expect(error.message).not_to include(nullifier)
          end
        end

        it "turns a timeout into a transient error" do
          stub_request(:get, "#{api_url}/chain/info").to_timeout
          error = captured_api_error { client.chain_info }
          expect(error.status).to be_nil
          expect(error).to be_transient
        end

        it "turns a 4xx into a transient error too" do
          stub_request(:get, "#{api_url}/chain/info").to_return(status: 400, body: "{}", headers: json_headers)
          expect(captured_api_error { client.chain_info }).to be_transient
        end

        it "uses 5 second timeouts" do
          connection = client.send(:connection)
          expect([connection.options.timeout, connection.options.open_timeout]).to eq([5, 5])
        end
      end
    end
  end
end
