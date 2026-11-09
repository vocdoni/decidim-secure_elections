# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe ResizeCensusJob do
        include_context "with a csp root and chain"

        let(:api_url) { "https://saas-api.example.org" }
        let(:process_id) { "6885f0c2c1a4e2f0b1d33a01" }
        let(:size_url) { "#{api_url}/processes/#{process_id}/external-csp/size" }
        let(:checkout_url) { "#{api_url}/processes/#{process_id}/census/checkout" }
        let(:component) { create(:elections_component) }
        let(:organization) { component.organization }
        let(:election) { create(:election, :published, :ongoing, :with_internal_users_census, component:) }
        let!(:voters) { create_list(:user, 5, :confirmed, organization:) }
        let(:roster) { election.census.count(election) }
        let(:census_size) { Vocdoni.declared_census_size(election, roster) }
        let!(:vocdoni_process) do
          create(:vocdoni_process, :published, election:, vocdoni_process_id: process_id, csp_state: "verified", census_size:)
        end
        let(:seed) { SecureRandom.hex(12) }
        let!(:csp_election) do
          create(:vocdoni_csp_election, process: vocdoni_process, seed:, census_root: derived_census_root(seed), upstream_id: SecureRandom.hex(32))
        end

        def chain_at(*sizes)
          stub_chain_election(csp_election.upstream_id, *sizes.map { |size| chain_election(csp_election, max_census_size: size) })
        end

        def grow_roster(by)
          create_list(:user, by, :confirmed, organization:)
          Vocdoni.declared_census_size(election, election.census.count(election))
        end

        def saas_error(status, code)
          json_response({ error: "nope", code: }, status:)
        end

        context "when the roster fits and the chain has the room" do
          before { chain_at(census_size) }

          it "calls no SaaS route" do
            described_class.perform_now(vocdoni_process.id)
            expect(a_request(:any, /#{Regexp.escape(api_url)}/)).not_to have_been_made
            expect(vocdoni_process.reload.census_size).to eq(census_size)
          end
        end

        context "when the roster outgrows the census size" do
          let!(:target) { grow_roster(3) }

          it "asks for the declared size, awaits the SaaS job and records the chain size" do
            expect(target).to be > census_size
            chain_at(census_size, target)
            stub_request(:post, size_url).with(body: { "size" => target }).to_return(json_response({ jobId: "job-9" }, status: 202))
            stub_request(:get, "#{api_url}/jobs/job-9").to_return(json_response({ status: "completed" }))

            described_class.perform_now(vocdoni_process.id)

            expect(a_request(:get, "#{api_url}/jobs/job-9")).to have_been_made
            expect(vocdoni_process.reload.census_size).to eq(target)
          end

          it "confirms on chain without awaiting when every open election already has the room" do
            chain_at(census_size, target)
            stub_request(:post, size_url).to_return(json_response({ jobId: "" }))

            described_class.perform_now(vocdoni_process.id)

            expect(a_request(:get, %r{/jobs/})).not_to have_been_made
            expect(vocdoni_process.reload.census_size).to eq(target)
          end

          it "retries while the chain is still below the target" do
            chain_at(census_size)
            stub_request(:post, size_url).to_return(json_response({ jobId: "" }))

            expect { described_class.perform_now(vocdoni_process.id) }.to have_enqueued_job(described_class).with(vocdoni_process.id)
            expect(vocdoni_process.reload.census_size).to eq(census_size)
          end

          it "records the failure after the last retry of a failed SaaS job" do
            chain_at(census_size)
            stub_request(:post, size_url).to_return(json_response({ jobId: "job-9" }, status: 202))
            stub_request(:get, "#{api_url}/jobs/job-9").to_return(json_response({ status: "failed", errors: ["tx rejected"] }))

            perform_enqueued_jobs { described_class.perform_later(vocdoni_process.id) }

            expect(a_request(:post, size_url)).to have_been_made.times(5)
            vocdoni_process.reload
            expect(vocdoni_process.census_size).to eq(census_size)
            expect(vocdoni_process.last_error).to include("census resize failed")
            expect(vocdoni_process.metadata.dig("last_error", "step")).to eq("resize")
            expect(vocdoni_process.state).to eq("published")
          end

          context "when the growth is not paid for" do
            before do
              chain_at(census_size, target)
              stub_request(:post, size_url).to_return(saas_error(402, 40_174)).then.to_return(json_response({ jobId: "" }))
            end

            it "pays from the integrator wallet and asks again" do
              stub_request(:post, checkout_url).to_return(json_response({ amountCents: 120, currency: "eur" }))

              described_class.perform_now(vocdoni_process.id)

              expect(a_request(:post, checkout_url).with do |req|
                body = JSON.parse(req.body)
                body["censusSize"] == target && body["returnURL"].end_with?("/elections/#{election.id}/dashboard")
              end).to have_been_made.once
              expect(a_request(:post, size_url)).to have_been_made.twice
              expect(vocdoni_process.reload.census_size).to eq(target)
            end

            it "reports a short integrator wallet without retrying" do
              stub_request(:post, checkout_url).to_return(saas_error(402, 40_175))

              expect { described_class.perform_now(vocdoni_process.id) }.not_to have_enqueued_job(described_class)

              expect(a_request(:post, size_url)).to have_been_made.once
              vocdoni_process.reload
              expect(vocdoni_process.census_size).to eq(census_size)
              expect(vocdoni_process.last_error).to eq("integrator wallet short")
              expect(vocdoni_process.state).to eq("published")
            end

            it "reports a payment a person would have to complete without retrying" do
              stub_request(:post, checkout_url).to_return(json_response({ clientSecret: "cs_x", sessionId: "cs_test_1", amountCents: 500, currency: "eur" }))

              expect { described_class.perform_now(vocdoni_process.id) }.not_to have_enqueued_job(described_class)

              expect(a_request(:post, size_url)).to have_been_made.once
              expect(vocdoni_process.reload.last_error).to eq("census growth needs payment")
              expect(vocdoni_process.census_size).to eq(census_size)
            end
          end
        end

        it "does nothing once no election takes votes" do
          grow_roster(3)
          stub_chain_election(csp_election.upstream_id, chain_election(csp_election, max_census_size: census_size, status: "ENDED"))
          described_class.perform_now(vocdoni_process.id)
          expect(a_request(:any, /#{Regexp.escape(api_url)}/)).not_to have_been_made
        end
      end
    end
  end
end
