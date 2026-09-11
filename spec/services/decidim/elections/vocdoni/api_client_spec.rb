# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    describe ApiClient do
      subject(:client) { described_class.new }

      let(:api_url) { "https://saas-api-stg.vocdoni.net" }
      let(:api_key) { "vsk_0123456789abcdef" }
      let(:org_address) { "0x0000000000000000000000000000000000000001" }
      let(:process_id) { "6885f0c2c1a4e2f0b1d33a01" }
      let(:json_headers) { { "Content-Type" => "application/json" } }

      def vocdoni_fixture(name)
        Decidim::Elections::Vocdoni::Engine.root.join("spec", "fixtures", "vocdoni", "#{name}.json").read
      end

      # Captures the raised error instead of relying on a block attached to
      # `raise_error`, which would silently never run when written with do/end.
      def captured_api_error
        yield
        raise "expected Decidim::Elections::Vocdoni::ApiError to be raised, but nothing was"
      rescue Decidim::Elections::Vocdoni::ApiError => e
        e
      end

      before do
        allow(Decidim::Elections::Vocdoni).to receive_messages(api_url:, api_key:, org_address:)
      end

      # The key is deliberately not a public reader, and `#inspect` deliberately
      # does not print it: either one would put `vsk_…` in full into a Rails
      # error page, a console session or an exception tracker's payload.
      describe "#inspect" do
        it "names the API it talks to and whether it is authenticated, and nothing else" do
          expect(client.inspect).to eq(%(#<Decidim::Elections::Vocdoni::ApiClient api_url="#{api_url}" authenticated=true>))
          expect(client.inspect).not_to include(api_key)
          expect(client).not_to respond_to(:api_key)
        end
      end

      describe "#initialize" do
        it "falls back to the module configuration" do
          expect(client.api_url).to eq(api_url)
          expect(client.send(:api_key)).to eq(api_key)
          expect(client.timeout).to eq(Decidim::Elections::Vocdoni.timeout)
          expect(client.open_timeout).to eq(Decidim::Elections::Vocdoni.open_timeout)
        end

        it "accepts overrides" do
          other = described_class.new(api_url: "https://example.org/api", api_key: "vsk_other", timeout: 3, open_timeout: 1, default_locale: "ca")

          expect(other.api_url).to eq("https://example.org/api")
          expect(other.send(:api_key)).to eq("vsk_other")
          expect(other.timeout).to eq(3)
          expect(other.open_timeout).to eq(1)
          expect(other.default_locale).to eq("ca")
        end
      end

      describe "sub-clients" do
        it "exposes and memoizes each one" do
          expect(client.elections).to be_a(described_class::Elections)
          expect(client.organizations).to be_a(described_class::Organizations)
          expect(client.census).to be_a(described_class::Census)
          expect(client.jobs).to be_a(described_class::Jobs)

          expect(client.elections).to equal(client.elections)
        end
      end

      describe "#localize" do
        it "delegates to the shared helper with the client default locale" do
          other = described_class.new(default_locale: "ca")

          expect(other.localize({ "en" => "Hi", "ca" => "Hola" })).to eq(
            "default" => "Hola", "en" => "Hi", "ca" => "Hola"
          )
          expect(client.localize("Hi")).to eq("default" => "Hi")
        end
      end

      describe "authenticated requests" do
        let!(:request) do
          stub_request(:post, "#{api_url}/processes")
            .with(
              body: { "title" => { "default" => "Hi" } },
              headers: {
                "Authorization" => "Bearer #{api_key}",
                "Accept" => "application/json",
                "Content-Type" => "application/json",
                "User-Agent" => "decidim-elections-vocdoni/#{Decidim::Elections::Vocdoni::VERSION}"
              }
            )
            .to_return(status: 200, body: vocdoni_fixture("process_created"), headers: json_headers)
        end

        it "sends the API key and parses the response" do
          expect(client.post("/processes", body: { "title" => { "default" => "Hi" } })).to eq("processId" => process_id)
          expect(request).to have_been_requested
        end

        it "validates the configuration first" do
          allow(Decidim::Elections::Vocdoni).to receive(:org_address).and_return(nil)

          expect { client.post("/processes", body: { "title" => { "default" => "Hi" } }) }
            .to raise_error(Decidim::Elections::Vocdoni::ConfigurationError, /org_address/)
          expect(request).not_to have_been_requested
        end
      end

      describe "public requests" do
        let!(:request) do
          stub_request(:get, "#{api_url}/processes/#{process_id}")
            .with { |http_request| !http_request.headers.has_key?("Authorization") }
            .to_return(status: 200, body: vocdoni_fixture("process"), headers: json_headers)
        end

        it "never sends the API key with auth: :none" do
          expect(client.get("/processes/#{process_id}", auth: :none)["chainId"]).to eq("vocdoni/LTS/1.2")
          expect(request).to have_been_requested
        end

        it "works without any API key at all" do
          allow(Decidim::Elections::Vocdoni).to receive(:api_key).and_return(nil)

          expect(described_class.new.get("/processes/#{process_id}", auth: :optional)["id"]).to eq(process_id)
          expect(request).to have_been_requested
        end

        it "does not validate the configuration" do
          allow(Decidim::Elections::Vocdoni).to receive_messages(api_key: nil, org_address: nil)

          expect { described_class.new.get("/processes/#{process_id}", auth: :none) }.not_to raise_error
        end

        it "raises when there is no API url" do
          allow(Decidim::Elections::Vocdoni).to receive(:api_url).and_return(nil)

          expect { described_class.new.get("/processes/#{process_id}", auth: :none) }
            .to raise_error(Decidim::Elections::Vocdoni::ConfigurationError, /api_url/)
        end
      end

      describe "auth: :optional" do
        it "sends the API key when there is one, so that drafts are readable" do
          request = stub_request(:get, "#{api_url}/processes/#{process_id}")
                    .with(headers: { "Authorization" => "Bearer #{api_key}" })
                    .to_return(status: 200, body: vocdoni_fixture("process"), headers: json_headers)

          client.get("/processes/#{process_id}", auth: :optional)

          expect(request).to have_been_requested
        end
      end

      describe "unknown auth modes" do
        it "raises" do
          expect { client.get("/processes", auth: :whatever) }.to raise_error(ArgumentError, /Unknown auth mode/)
        end
      end

      describe "query parameters" do
        it "stringifies and appends them" do
          request = stub_request(:get, "#{api_url}/processes/#{process_id}/participants")
                    .with(query: { "field" => "memberNumber", "value" => "1001" })
                    .to_return(status: 200, body: vocdoni_fixture("process_participants"), headers: json_headers)

          client.get("/processes/#{process_id}/participants", params: { field: "memberNumber", value: "1001" })

          expect(request).to have_been_requested
        end
      end

      describe "base url handling" do
        it "keeps a path prefix configured in the API url" do
          allow(Decidim::Elections::Vocdoni).to receive(:api_url).and_return("https://example.org/vocdoni/")
          request = stub_request(:get, "https://example.org/vocdoni/processes/#{process_id}")
                    .to_return(status: 200, body: vocdoni_fixture("process"), headers: json_headers)

          described_class.new.get("/processes/#{process_id}")

          expect(request).to have_been_requested
        end
      end

      describe "error mapping" do
        it "raises an ApiError carrying status, code and body" do
          stub_request(:post, "#{api_url}/processes")
            .to_return(status: 400, body: vocdoni_fixture("error_invalid_body"), headers: json_headers)

          error = captured_api_error { client.post("/processes", body: { "title" => "Hi" }) }

          expect(error.status).to eq(400)
          expect(error.code).to eq(40_004)
          expect(error.body).to eq("error" => "invalid JSON request body", "code" => 40_004)
          expect(error.message).to include("HTTP 400")
          expect(error.message).to include("code 40004")
          expect(error.message).to include("invalid JSON request body")
          expect(error.message).to include("POST")
        end

        it "maps a 401" do
          stub_request(:get, "#{api_url}/processes/#{process_id}/validation")
            .to_return(status: 401, body: vocdoni_fixture("error_unauthorized"), headers: json_headers)

          error = captured_api_error { client.get("/processes/#{process_id}/validation") }

          expect(error.status).to eq(401)
          expect(error.code).to eq(40_001)
          expect(error.message).to include("user not authorized")
        end

        it "copes with an empty error body" do
          stub_request(:get, "#{api_url}/processes/#{process_id}/validation").to_return(status: 404, body: "")

          error = captured_api_error { client.get("/processes/#{process_id}/validation") }

          expect(error.status).to eq(404)
          expect(error.code).to be_nil
          expect(error.body).to eq({})
        end

        it "copes with a non-JSON error body" do
          stub_request(:post, "#{api_url}/processes")
            .to_return(status: 502, body: "<html>bad gateway</html>", headers: { "Content-Type" => "text/html" })

          error = captured_api_error { client.post("/processes", body: { "title" => "Hi" }) }

          expect(error.status).to eq(502)
          expect(error.code).to be_nil
          expect(error.body).to eq("<html>bad gateway</html>")
        end

        it "wraps transport failures" do
          stub_request(:post, "#{api_url}/processes").to_timeout

          error = captured_api_error { client.post("/processes", body: { "title" => "Hi" }) }

          expect(error.status).to be_nil
          expect(error.message).to include("POST /processes failed")
        end
      end

      describe "response parsing" do
        it "turns an empty successful body into an empty hash" do
          stub_request(:post, "#{api_url}/processes/#{process_id}/publish").to_return(status: 204, body: "")

          expect(client.post("/processes/#{process_id}/publish")).to eq({})
        end

        it "keeps a JSON array" do
          stub_request(:get, "#{api_url}/organizations/types")
            .to_return(status: 200, body: '[{"name":"association"}]', headers: json_headers)

          expect(client.get("/organizations/types")).to eq([{ "name" => "association" }])
        end
      end

      describe "retries" do
        it "retries an idempotent read" do
          request = stub_request(:get, "#{api_url}/processes/#{process_id}")
                    .to_return({ status: 503, body: "", headers: json_headers },
                               { status: 200, body: vocdoni_fixture("process"), headers: json_headers })

          expect(client.get("/processes/#{process_id}")["id"]).to eq(process_id)
          expect(request).to have_been_requested.twice
        end

        it "never retries a write, which could publish twice" do
          request = stub_request(:post, "#{api_url}/processes/#{process_id}/publish")
                    .to_return(status: 503, body: "", headers: json_headers)

          expect { client.post("/processes/#{process_id}/publish") }.to raise_error(Decidim::Elections::Vocdoni::ApiError)
          expect(request).to have_been_requested.once
        end
      end
    end
  end
end
end
