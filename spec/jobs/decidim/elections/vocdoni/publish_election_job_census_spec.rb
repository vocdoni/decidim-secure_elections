# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe PublishElectionJob do
        subject(:job) { described_class.new }

        let(:organization) { create(:organization, available_authorizations: %w(dummy_authorization_handler)) }
        let(:component) { create(:elections_component, organization:) }
        let(:two_fa_fields) { ["email"] }
        let!(:vocdoni_process) do
          create(:vocdoni_process, election:, metadata: { "settings" => { "twofa_fields" => two_fa_fields } })
        end

        let(:organizations_api) { instance_double(ApiClient::Organizations) }
        let(:jobs_api) { instance_double(ApiClient::Jobs) }
        let(:client) { instance_double(ApiClient, organizations: organizations_api, jobs: jobs_api) }

        def bootstrap!
          job.send(:bootstrap!, election.id)
          allow(job).to receive(:client).and_return(client)
        end

        def credential(subject)
          VoterCredential.for(election, subject)
        end

        def roster
          job.send(:voter_payloads)
        end

        context "with an internal_users census" do
          let(:election) do
            create(:election, component:, census_manifest: "internal_users",
                              census_settings: { "authorization_handlers" => authorization_handlers })
          end
          let(:authorization_handlers) { {} }
          let!(:ada) { create(:user, :confirmed, organization:, name: "Ada Lovelace", email: "ada@example.org") }
          let!(:grace) { create(:user, :confirmed, organization:, name: "Grace Hopper", email: "grace@example.org") }

          before do
            create(:user, organization:) # not confirmed: out of upstream's query
            create(:user, :confirmed) # another organization
            bootstrap!
          end

          it "pushes every participant upstream's census admits, with no cap" do
            expect(roster).to contain_exactly(
              { "memberNumber" => credential(ada), "name" => "Ada Lovelace", "email" => "ada@example.org" },
              { "memberNumber" => credential(grace), "name" => "Grace Hopper", "email" => "grace@example.org" }
            )
          end

          it "never sends the Decidim user id as the credential" do
            expect(roster.pluck("memberNumber")).not_to include(ada.id.to_s, grace.id.to_s)
          end

          context "when the census requires an authorization" do
            let(:authorization_handlers) { { "dummy_authorization_handler" => { "options" => options } } }
            let(:options) { {} }

            before do
              create(:authorization, :granted, user: ada, organization:, name: "dummy_authorization_handler",
                                               metadata: { "postal_code" => "08001" })
            end

            it "pushes only the authorized participants" do
              expect(roster.pluck("memberNumber")).to eq([credential(ada)])
            end

            context "and its options filter the authorizations" do
              let(:options) { { "allowed_postal_codes" => "08002" } }
              let!(:linus) { create(:user, :confirmed, organization:) }

              before do
                create(:authorization, :granted, user: linus, organization:, name: "dummy_authorization_handler",
                                                 metadata: { "postal_code" => "08002" })
              end

              it "applies them as Decidim's census check does" do
                expect(roster.pluck("memberNumber")).to eq([credential(linus)])
              end
            end
          end

          context "when SMS is the second factor" do
            let(:two_fa_fields) { ["phone"] }

            before do
              create(:authorization, :granted, user: ada, organization:, name: "dummy_authorization_handler",
                                               metadata: { "phone_number" => "+34600000001" })
            end

            it "carries the phone found in the participant's authorizations" do
              expect(roster.find { |member| member["memberNumber"] == credential(ada) }["phone"]).to eq("+34600000001")
              expect(roster.find { |member| member["memberNumber"] == credential(grace) }).not_to have_key("phone")
            end
          end

          context "when SMS is not a second factor" do
            before do
              create(:authorization, :granted, user: ada, organization:, name: "dummy_authorization_handler",
                                               metadata: { "phone_number" => "+34600000001" })
            end

            it "keeps the phone in Decidim" do
              expect(roster.flat_map(&:keys)).not_to include("phone")
            end
          end
        end

        context "with a token_csv census" do
          let(:election) { create(:election, component:, census_manifest: "token_csv") }
          let!(:alice) { create(:election_voter, election:, data: { "email" => "alice@example.org", "token" => "S3CRET", "phone" => "600000002" }) }
          let!(:bob) { create(:election_voter, election:, data: { "email" => "bob@example.org", "token" => "OTHER" }) }

          before do
            create(:election_voter, data: { "email" => "elsewhere@example.org", "token" => "X" })
            bootstrap!
          end

          it "pushes the imported rows, keyed by their credential, without the access token" do
            expect(roster).to contain_exactly(
              { "memberNumber" => credential(alice), "email" => "alice@example.org" },
              { "memberNumber" => credential(bob), "email" => "bob@example.org" }
            )
          end

          context "when SMS is the second factor" do
            let(:two_fa_fields) { %w(email phone) }

            it "carries the row's phone" do
              expect(roster.find { |member| member["memberNumber"] == credential(alice) }["phone"]).to eq("600000002")
            end
          end
        end

        describe "the census readiness gate" do
          let(:election) { create(:election, component:, census_manifest: "token_csv") }

          before { bootstrap! }

          it "refuses to push a census that is not ready" do
            expect(organizations_api).not_to receive(:add_members)

            expect { job.send(:prepare_census!) }.to raise_error(ApiError, /census is not ready/) do |error|
              expect(error.transient?).to be(false)
            end
          end
        end

        describe "pushing the roster" do
          let(:election) { create(:election, component:, census_manifest: "token_csv") }
          let!(:voters) { Array.new(5) { |n| create(:election_voter, election:, data: { "email" => "v#{n}@example.org", "token" => "t#{n}" }) } }
          let(:upstream) { [] }
          let(:pushed) { [] }

          before do
            allow(described_class).to receive(:member_batch_size).and_return(2)
            allow(organizations_api).to receive(:members) do |_org, page:, limit:|
              expect(limit).to eq(described_class::MEMBERS_PAGE_SIZE)
              rows = upstream.each_slice(limit).to_a[page - 1] || []
              { "members" => rows, "pagination" => { "nextPage" => page + 1 } }
            end
            allow(organizations_api).to receive(:add_members) do |_org, batch|
              pushed << batch
              batch.each { |member| upstream << member.merge("id" => "m-#{member["memberNumber"][0, 8]}") }
              { "jobId" => "job-#{pushed.size}" }
            end
            allow(jobs_api).to receive(:wait_for).and_return({ "status" => "completed" })
            bootstrap!
          end

          it "sends the members in batches and finds every one of them by credential" do
            job.send(:ensure_members_pushed!)

            expect(pushed.map(&:size)).to eq([2, 2, 1])
            expect(job.send(:resolve_member_ids!)).to match_array(voters.map { |voter| "m-#{credential(voter)[0, 8]}" })
          end

          context "when some members are already upstream" do
            before do
              upstream << { "id" => "old", "memberNumber" => credential(voters.first), "email" => "v0@example.org" }
              # Same person, credential of another election: must not be reused.
              upstream << { "id" => "stale", "memberNumber" => "f" * 64, "email" => "v1@example.org" }
            end

            it "pushes only the credentials the memberbase lacks" do
              job.send(:ensure_members_pushed!)

              expect(pushed.flatten.pluck("memberNumber")).to match_array(voters.drop(1).map { |voter| credential(voter) })
              ids = job.send(:resolve_member_ids!)
              expect(ids).to include("old")
              expect(ids).not_to include("stale")
            end
          end

          it "fails loudly when a pushed voter cannot be found upstream" do
            job.send(:ensure_members_pushed!)
            upstream.pop

            expect { job.send(:resolve_member_ids!) }.to raise_error(ApiError, /1 of 5 voters are missing/)
          end

          it "stops at a batch the SaaS rejects" do
            allow(jobs_api).to receive(:wait_for).and_return({ "status" => "completed", "errors" => ["bad email"] })

            expect { job.send(:ensure_members_pushed!) }.to raise_error(ApiError, /rejected 1 of 2 voters: bad email/)
            expect(pushed.size).to eq(1)
          end
        end
      end
    end
  end
end
