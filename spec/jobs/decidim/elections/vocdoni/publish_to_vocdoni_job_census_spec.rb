# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Vocdoni
      describe PublishToVocdoniJob do
        subject(:job) { described_class.new }

        def bootstrap(election)
          job.instance_variable_set(:@election, election)
          job.instance_variable_set(:@process, election.vocdoni_process)
        end

        describe "#voter_to_member" do
          let(:election) { create(:election) }
          let(:voter) do
            Decidim::Elections::Voter.create!(
              election:,
              data: { "memberNumber" => "000123", "weight" => 3, "token" => "SECRET", "name" => "", "email" => nil }
            )
          end

          it "sends the weight as a string, drops the token and every blank value" do
            expect(job.send(:voter_to_member, voter)).to eq("memberNumber" => "000123", "weight" => "3")
          end
        end

        describe "#user_to_member" do
          let(:organization) { create(:organization) }
          let(:user) { create(:user, organization:, name: "Ada Lovelace", email: "ada@example.org") }

          it "maps the user's id, name and email as-is" do
            expect(job.send(:user_to_member, user)).to eq(
              "memberNumber" => user.id.to_s,
              "name" => "Ada Lovelace",
              "email" => "ada@example.org"
            )
          end
        end

        describe "#auth_fields" do
          context "when it is a file census" do
            let(:election) { create(:election, census_manifest: "token_csv", census_settings: { "identifiers" => identifiers }) }
            let(:identifiers) { %w(memberNumber name token) }

            before { bootstrap(election) }

            it "is the chosen identifiers that the SaaS accepts as auth fields" do
              # "token" is not usable as an authField; it is filtered out.
              expect(job.send(:auth_fields)).to eq(%w(memberNumber name))
            end

            context "when nothing was chosen" do
              let(:identifiers) { [] }

              it "raises a clear, non-transient error" do
                expect { job.send(:auth_fields) }.to raise_error(Decidim::Elections::Vocdoni::ApiError) do |error|
                  expect(error.code).to eq("no_identifiers")
                  expect(error.transient?).to be(false)
                end
              end
            end
          end

          context "when it is a registered participants census" do
            let(:election) { create(:election, :with_internal_users_census) }

            before { bootstrap(election) }

            it "is the participant number" do
              expect(job.send(:auth_fields)).to eq(["memberNumber"])
            end
          end
        end

        # authFields/twoFaFields as they would actually be sent, for the
        # combinations the Census tab can now produce now that email/phone are
        # allowed identifiers: a plain AUTH pair, a contact detail alone (its
        # one-time code is what proves the person, so authFields is legitimately
        # empty), a mix of the two, and an access code alone (which the service
        # cannot use at all, so publishing is refused).
        describe "#auth_fields and #two_fa_fields together" do
          def process_for(election)
            Vocdoni::Process.create!(election:, state: "pending")
            bootstrap(election)
          end

          context "when the census is identified by name and a national ID number" do
            let(:election) { create(:election, census_manifest: "token_csv", census_settings: { "identifiers" => %w(name nationalId) }) }

            before { process_for(election) }

            it "sends both as authFields and sends no one-time code" do
              expect(job.send(:auth_fields)).to eq(%w(name nationalId))
              expect(job.send(:two_fa_fields)).to eq([])
            end
          end

          context "when the census is identified by email alone" do
            let(:election) { create(:election, census_manifest: "token_csv", census_settings: { "identifiers" => %w(email) }) }

            before { process_for(election) }

            it "sends no authFields: the one-time code sent to that address is what proves the person" do
              expect(job.send(:auth_fields)).to eq([])
              expect(job.send(:two_fa_fields)).to eq(%w(email))
            end
          end

          context "when the census is identified by a national ID number and email" do
            let(:election) { create(:election, census_manifest: "token_csv", census_settings: { "identifiers" => %w(nationalId email) }) }

            before { process_for(election) }

            it "sends the national ID as an authField and turns the email code on" do
              expect(job.send(:auth_fields)).to eq(%w(nationalId))
              expect(job.send(:two_fa_fields)).to eq(%w(email))
            end
          end

          context "when the census is identified only by an access code we hand out" do
            let(:election) { create(:election, census_manifest: "token_csv", census_settings: { "identifiers" => %w(token) }) }

            before { process_for(election) }

            it "raises no_identifiers: the secure voting service has nowhere to put it" do
              expect { job.send(:auth_fields) }.to raise_error(Decidim::Elections::Vocdoni::ApiError) do |error|
                expect(error.code).to eq("no_identifiers")
                expect(error.transient?).to be(false)
              end
            end
          end
        end

        describe ".preview_census!" do
          let(:election) { create(:election, census_manifest: "token_csv", census_settings: { "identifiers" => %w(memberNumber) }) }

          # This platform's own ceiling on what it will send in one request,
          # not a claim about the organisation's Vocdoni plan: it reports
          # under its own code so the two are never confused on the page.
          context "when the roster is bigger than this platform sends in one request" do
            around do |example|
              previous = ENV.fetch("VOCDONI_MAX_ROSTER", nil)
              ENV["VOCDONI_MAX_ROSTER"] = "2"
              example.run
              ENV["VOCDONI_MAX_ROSTER"] = previous
            end

            before do
              Vocdoni::Process.create!(election:, state: "pending")
              3.times { |i| Decidim::Elections::Voter.create!(election:, data: { "memberNumber" => (i + 1).to_s }) }
            end

            it "records a failed pre-flight instead of raising, and never touches the API" do
              expect { described_class.preview_census!(election.id) }.not_to raise_error

              validation = Vocdoni::Process.find_by(decidim_election_id: election.id).census_validation
              expect(validation["ok"]).to be(false)
              expect(validation["code"]).to eq("roster_over_ceiling")
            end
          end

          context "when a person in the census has no identity field at all" do
            let(:election) { create(:election, census_manifest: "token_csv", census_settings: { "identifiers" => %w(name) }) }
            let(:organizations_double) { instance_double(Decidim::Elections::Vocdoni::ApiClient::Organizations) }
            let(:client_double) { instance_double(Decidim::Elections::Vocdoni::ApiClient, organizations: organizations_double) }

            before do
              Vocdoni::Process.create!(election:, state: "pending")
              Decidim::Elections::Voter.create!(election:, data: { "name" => "Nameless" })
              allow_any_instance_of(described_class).to receive(:client).and_return(client_double) # rubocop:disable RSpec/AnyInstance
              allow(organizations_double).to receive(:members).and_return({ "members" => [], "pagination" => {} })
              allow(organizations_double).to receive(:add_members).and_return({})
            end

            it "records a no_identity failure instead of raising" do
              expect { described_class.preview_census!(election.id) }.not_to raise_error

              validation = Vocdoni::Process.find_by(decidim_election_id: election.id).census_validation
              expect(validation["ok"]).to be(false)
              expect(validation["code"]).to eq("no_identity")
            end
          end

          context "with a successful roster push and census validation" do
            let(:election) do
              create(:election, census_manifest: "token_csv", census_settings: { "identifiers" => %w(memberNumber) })
            end
            let(:organizations_double) { instance_double(Decidim::Elections::Vocdoni::ApiClient::Organizations) }
            let(:elections_double) { instance_double(Decidim::Elections::Vocdoni::ApiClient::Elections) }
            let(:client_double) do
              instance_double(Decidim::Elections::Vocdoni::ApiClient, organizations: organizations_double, elections: elections_double)
            end

            let(:pushed_members) do
              {
                "members" => [
                  { "id" => "m1", "memberNumber" => "1" },
                  { "id" => "m2", "memberNumber" => "2" },
                  { "id" => "m3", "memberNumber" => "3" }
                ],
                "pagination" => {}
              }
            end

            before do
              Vocdoni::Process.create!(election:, state: "pending", metadata: { "settings" => { "twofa_fields" => %w(email) } })
              3.times { |i| Decidim::Elections::Voter.create!(election:, data: { "memberNumber" => (i + 1).to_s }) }

              allow_any_instance_of(described_class).to receive(:client).and_return(client_double) # rubocop:disable RSpec/AnyInstance
              allow(organizations_double).to receive(:members).and_return(
                { "members" => [], "pagination" => {} }, pushed_members
              )
              allow(organizations_double).to receive(:add_members).and_return({})
              allow(organizations_double).to receive(:create_group).and_return({ "id" => "g1" })
              allow(elections_double).to receive(:validate_census).and_return({})
            end

            it "records a passing pre-flight for the whole roster" do
              described_class.preview_census!(election.id)

              process = Vocdoni::Process.find_by(decidim_election_id: election.id)
              expect(process.census_validation["ok"]).to be(true)
              expect(process.census_validation["size"]).to eq(3)
              expect(process.census_group_id).to eq("g1")
            end

            it "sends the chosen identifiers as authFields and the configured code as twoFaFields" do
              expect(elections_double).to receive(:validate_census) do |_org_address, census|
                expect(census["authFields"]).to eq(%w(memberNumber))
                expect(census["twoFaFields"]).to eq(%w(email))
                {}
              end

              described_class.preview_census!(election.id)
            end
          end
        end
      end
    end
  end
end
