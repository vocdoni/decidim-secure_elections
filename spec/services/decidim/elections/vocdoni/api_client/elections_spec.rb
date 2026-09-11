# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    describe ApiClient::Elections do
      subject(:elections) { client.elections }

      let(:client) { ApiClient.new }
      let(:api_url) { "https://saas-api-stg.vocdoni.net" }
      let(:api_key) { "vsk_0123456789abcdef" }
      let(:org_address) { "0x0000000000000000000000000000000000000001" }
      let(:group_id) { "000000000000000000000001" }
      let(:process_id) { "6885f0c2c1a4e2f0b1d33a01" }
      let(:question_id) { "6885f0c2c1a4e2f0b1d33a02" }
      let(:json_headers) { { "Content-Type" => "application/json" } }

      def vocdoni_fixture(name)
        Decidim::Elections::Vocdoni::Engine.root.join("spec", "fixtures", "vocdoni", "#{name}.json").read
      end

      before do
        allow(Decidim::Elections::Vocdoni).to receive_messages(api_url:, api_key:, org_address:)
      end

      describe "#create" do
        let(:payload) do
          {
            title: { "en" => "Board election", "ca" => "Eleccions" },
            description: "Pick the next chair.",
            endDate: Time.utc(2026, 7, 29, 14, 51, 8),
            census: { authFields: ["memberNumber"], groupId: group_id, weighted: false },
            questions: [
              {
                title: "Who should chair the board?",
                type: "singlechoice",
                choices: [
                  { title: "Alice", value: 0 },
                  { title: { "en" => "Bob", "ca" => "En Bob" }, value: 1 }
                ]
              }
            ]
          }
        end

        let(:expected_body) do
          {
            "orgAddress" => org_address,
            "title" => { "default" => "Board election", "en" => "Board election", "ca" => "Eleccions" },
            "description" => { "default" => "Pick the next chair." },
            "endDate" => "2026-07-29T14:51:08Z",
            "census" => { "authFields" => ["memberNumber"], "groupId" => group_id, "weighted" => false },
            "questions" => [
              {
                "title" => { "default" => "Who should chair the board?" },
                "type" => "singlechoice",
                "choices" => [
                  { "title" => { "default" => "Alice" }, "value" => 0 },
                  { "title" => { "default" => "Bob", "en" => "Bob", "ca" => "En Bob" }, "value" => 1 }
                ]
              }
            ]
          }
        end

        let!(:request) do
          stub_request(:post, "#{api_url}/processes")
            .with(body: expected_body)
            .to_return(status: 200, body: vocdoni_fixture("process_created"), headers: json_headers)
        end

        it "posts a fully normalized draft and returns the process id" do
          expect(elections.create(payload)).to eq("processId" => process_id)
          expect(request).to have_been_requested
        end

        context "when an org address is given" do
          let(:payload) { super().merge(orgAddress: "0xdeadbeef") }
          let(:expected_body) { super().merge("orgAddress" => "0xdeadbeef") }

          it "never overrides it with the configured one" do
            elections.create(payload)

            expect(request).to have_been_requested
          end
        end

        context "when the question type is camelCased" do
          let(:payload) { super().tap { |draft| draft[:questions][0][:type] = "singleChoice" } }

          it "downcases it, since camelCase is rejected with code 40037" do
            elections.create(payload)

            expect(request).to have_been_requested
          end
        end

        context "when a description is blank" do
          let(:payload) { super().merge(description: "") }
          let(:expected_body) { super().except("description") }

          it "omits the key instead of sending a null" do
            elections.create(payload)

            expect(request).to have_been_requested
          end
        end

        context "when the start date is a zoned time" do
          let(:payload) { super().merge(startDate: Time.zone.parse("2026-07-27T16:51:08+02:00")) }
          let(:expected_body) { super().merge("startDate" => "2026-07-27T14:51:08Z") }

          it "sends it as a UTC timestamp" do
            elections.create(payload)

            expect(request).to have_been_requested
          end
        end

        context "when the dates are already formatted" do
          let(:payload) { super().merge(endDate: "2026-07-29T14:51:08Z") }

          it "passes them through" do
            elections.create(payload)

            expect(request).to have_been_requested
          end
        end

        context "with a multichoice question" do
          let(:payload) do
            super().tap do |draft|
              draft[:questions][0][:type] = "multichoice"
              draft[:questions][0][:typeSetup] = { maxChoices: 2, minChoices: 1, uniqueChoices: true }
            end
          end

          let(:expected_body) do
            super().tap do |body|
              body["questions"][0]["type"] = "multichoice"
              body["questions"][0]["typeSetup"] = { "maxChoices" => 2, "minChoices" => 1, "uniqueChoices" => true }
            end
          end

          it "passes the type setup through untouched" do
            elections.create(payload)

            expect(request).to have_been_requested
          end
        end
      end

      describe "#get" do
        it "reads the process, sending the API key so drafts are visible" do
          request = stub_request(:get, "#{api_url}/processes/#{process_id}")
                    .with(headers: { "Authorization" => "Bearer #{api_key}" })
                    .to_return(status: 200, body: vocdoni_fixture("process"), headers: json_headers)

          process = elections.get(process_id)

          expect(process["chainId"]).to eq("vocdoni/LTS/1.2")
          expect(process["questions"].first["upstreamId"]).to eq("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
          expect(process["questions"].first["ballotProtocol"]).to be_nil
          expect(request).to have_been_requested
        end

        it "can read anonymously" do
          request = stub_request(:get, "#{api_url}/processes/#{process_id}")
                    .with { |http_request| !http_request.headers.has_key?("Authorization") }
                    .to_return(status: 200, body: vocdoni_fixture("process"), headers: json_headers)

          expect(elections.get(process_id, authenticated: false)["id"]).to eq(process_id)
          expect(request).to have_been_requested
        end

        it "works on a client with no API key" do
          allow(Decidim::Elections::Vocdoni).to receive(:api_key).and_return(nil)
          request = stub_request(:get, "#{api_url}/processes/#{process_id}")
                    .to_return(status: 200, body: vocdoni_fixture("process"), headers: json_headers)

          expect(ApiClient.new.elections.get(process_id)["id"]).to eq(process_id)
          expect(request).to have_been_requested
        end
      end

      describe "#validate" do
        it "runs the publish-readiness dry run" do
          request = stub_request(:get, "#{api_url}/processes/#{process_id}/validation")
                    .to_return(status: 200, body: vocdoni_fixture("process_validation"), headers: json_headers)

          result = elections.validate(process_id)

          expect(result["valid"]).to be(false)
          expect(result["errors"]).to include("census is empty")
          expect(request).to have_been_requested
        end
      end

      describe "#publish" do
        it "enqueues the on-chain publication" do
          request = stub_request(:post, "#{api_url}/processes/#{process_id}/publish")
                    .to_return(status: 200, body: vocdoni_fixture("publish_enqueued"), headers: json_headers)

          expect(elections.publish(process_id)).to eq("jobId" => "6885f1a3c1a4e2f0b1d33a10")
          expect(request).to have_been_requested
        end
      end

      describe "#results" do
        it "reads the tallies" do
          request = stub_request(:get, "#{api_url}/processes/#{process_id}/results")
                    .to_return(status: 200, body: vocdoni_fixture("process_results"), headers: json_headers)

          results = elections.results(process_id)

          expect(results["questions"].first["questionId"]).to eq(question_id)
          expect(results["questions"].first["results"]).to eq([%w(1 1)])
          expect(request).to have_been_requested
        end

        it "can read anonymously" do
          request = stub_request(:get, "#{api_url}/processes/#{process_id}/results")
                    .with { |http_request| !http_request.headers.has_key?("Authorization") }
                    .to_return(status: 200, body: vocdoni_fixture("process_results"), headers: json_headers)

          elections.results(process_id, authenticated: false)

          expect(request).to have_been_requested
        end
      end

      describe "#bulk_set_question_status" do
        it "targets the given questions" do
          request = stub_request(:put, "#{api_url}/processes/#{process_id}/questions/status")
                    .with(body: { "status" => "ENDED", "questions" => [{ "id" => question_id }] })
                    .to_return(status: 200, body: vocdoni_fixture("status_change_enqueued"), headers: json_headers)

          expect(elections.bulk_set_question_status(process_id, status: "ENDED", question_ids: [question_id]))
            .to eq("jobId" => "6885f1a3c1a4e2f0b1d33a20")
          expect(request).to have_been_requested
        end

        it "targets every published question when no id is given" do
          request = stub_request(:put, "#{api_url}/processes/#{process_id}/questions/status")
                    .with(body: { "status" => "PAUSED" })
                    .to_return(status: 200, body: vocdoni_fixture("status_change_enqueued"), headers: json_headers)

          elections.bulk_set_question_status(process_id, status: :PAUSED)

          expect(request).to have_been_requested
        end
      end

      describe "#participants" do
        it "looks members up by census field" do
          request = stub_request(:get, "#{api_url}/processes/#{process_id}/participants")
                    .with(query: { "field" => "memberNumber", "value" => "1001" })
                    .to_return(status: 200, body: vocdoni_fixture("process_participants"), headers: json_headers)

          participants = elections.participants(process_id, field: :memberNumber, value: "1001")

          expect(participants["participants"].first["questions"].first["hasVoted"]).to be(true)
          expect(request).to have_been_requested
        end
      end
    end
  end
end
end
