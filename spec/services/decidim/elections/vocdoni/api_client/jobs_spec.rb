# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    describe ApiClient::Jobs do
      subject(:jobs) { client.jobs }

      let(:client) { ApiClient.new }
      let(:api_url) { "https://saas-api-stg.vocdoni.net" }
      let(:api_key) { "vsk_0123456789abcdef" }
      let(:org_address) { "0x0000000000000000000000000000000000000001" }
      let(:job_id) { "6885f1a3c1a4e2f0b1d33a10" }
      let(:job_url) { "#{api_url}/jobs/#{job_id}" }
      let(:json_headers) { { "Content-Type" => "application/json" } }

      def vocdoni_fixture(name)
        Decidim::Elections::Vocdoni::Engine.root.join("spec", "fixtures", "vocdoni", "#{name}.json").read
      end

      def json_response(name)
        { status: 200, body: vocdoni_fixture(name), headers: json_headers }
      end

      def captured_job_error
        yield
        raise "expected Decidim::Elections::Vocdoni::JobError to be raised, but nothing was"
      rescue Decidim::Elections::Vocdoni::JobError => e
        e
      end

      before do
        allow(Decidim::Elections::Vocdoni).to receive_messages(api_url:, api_key:, org_address:)
        allow(jobs).to receive(:sleep)
      end

      describe "#get" do
        it "reads the job" do
          request = stub_request(:get, job_url).to_return(json_response("job_completed"))

          job = jobs.get(job_id)

          expect(job["status"]).to eq("completed")
          expect(job["type"]).to eq("publish_voting_process")
          expect(request).to have_been_requested
        end
      end

      describe "#wait_for" do
        it "returns the completed job without sleeping when it is already done" do
          stub_request(:get, job_url).to_return(json_response("job_completed"))

          job = jobs.wait_for(job_id)

          expect(job["status"]).to eq("completed")
          expect(job["result"]["status"]).to eq("READY")
          expect(jobs).not_to have_received(:sleep)
          expect(a_request(:get, job_url)).to have_been_made.once
        end

        it "polls until the top-level status is completed" do
          stub_request(:get, job_url).to_return(
            json_response("job_pending"),
            json_response("job_pending"),
            json_response("job_completed")
          )

          expect(jobs.wait_for(job_id)["status"]).to eq("completed")
          expect(jobs).to have_received(:sleep).with(described_class::DEFAULT_INTERVAL).twice
          expect(a_request(:get, job_url)).to have_been_made.times(3)
        end

        it "reads only the top-level status, never the nested result status" do
          stub_request(:get, job_url).to_return(
            json_response("job_pending_nested_completed"),
            json_response("job_completed")
          )

          job = jobs.wait_for(job_id)

          # The first body carries `result.status == "completed"`, which is the
          # election's status and not the job's — stopping there would return a
          # job that is still running.
          expect(job["result"]["status"]).to eq("READY")
          expect(a_request(:get, job_url)).to have_been_made.twice
        end

        it "honours a custom interval" do
          stub_request(:get, job_url).to_return(json_response("job_pending"), json_response("job_completed"))

          jobs.wait_for(job_id, interval: 0.25)

          expect(jobs).to have_received(:sleep).with(0.25).once
        end

        it "raises a JobError when the job failed" do
          stub_request(:get, job_url).to_return(json_response("job_failed"))

          error = captured_job_error { jobs.wait_for(job_id) }

          expect(error).to be_a(Decidim::Elections::Vocdoni::ApiError)
          expect(error.message).to include(job_id)
          expect(error.message).to include("not enough balance to create the election; tx not committed")
          expect(error.body["status"]).to eq("failed")
          expect(jobs).not_to have_received(:sleep)
        end

        it "raises a JobError when the timeout elapses" do
          stub_request(:get, job_url).to_return(json_response("job_pending"))

          error = captured_job_error { jobs.wait_for(job_id, timeout: 0) }

          expect(error.message).to include("Timed out after 0s")
          expect(error.body["status"]).to eq("pending")
          expect(jobs).not_to have_received(:sleep)
          expect(a_request(:get, job_url)).to have_been_made.once
        end

        it "defaults to the configured job timeout" do
          allow(Decidim::Elections::Vocdoni).to receive(:job_timeout).and_return(0)
          stub_request(:get, job_url).to_return(json_response("job_pending"))

          error = captured_job_error { jobs.wait_for(job_id) }

          expect(error.message).to include("Timed out after 0s")
        end

        it "lets an API failure through" do
          stub_request(:get, job_url).to_return(status: 404, body: '{"error":"job not found","code":40404}', headers: json_headers)

          expect { jobs.wait_for(job_id) }.to raise_error(Decidim::Elections::Vocdoni::ApiError, /job not found/)
        end
      end
    end
  end
end
end
