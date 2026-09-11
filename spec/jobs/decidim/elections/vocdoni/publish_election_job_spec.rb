# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    describe PublishElectionJob do
      subject(:job) { described_class.new }

      # Driven through WebMock rather than doubles: the whole point of this job
      # is the *order* and the *bodies* of eight upstream calls, and a double
      # would happily accept a payload the API rejects.
      let(:api_url) { "https://saas-api.example.org" }
      let(:org_address) { "0x0000000000000000000000000000000000000001" }
      let(:json_headers) { { "Content-Type" => "application/json" } }

      # An election whose census already exists upstream: it points at a member
      # group and holds no local voter rows, so there is nothing to import and
      # nothing to group. Building the census out of Decidim's own voters is
      # exercised on its own further down, where the group is rebuilt.
      let(:election) { create(:vocdoni_election, :ready_to_publish, census_members_count: 0, census_group_id: group_id) }
      let(:group_id) { "000000000000000000000001" }
      let(:new_group_id) { "6a677022622d94e7c9a1929a" }
      let(:census_id) { "6885f0c2c1a4e2f0b1d33b01" }
      let(:process_id) { "6885f0c2c1a4e2f0b1d33a01" }
      let(:publish_job_id) { "6885f1a3c1a4e2f0b1d33a10" }

      # Bodies recorded by the stubs, which is the only way to assert on
      # something Faraday serialized.
      let(:captured) { {} }
      let(:payload) { captured.fetch(:process) }

      let(:remote_process) { JSON.parse(vocdoni_fixture("process")) }
      let(:draft_process) do
        remote_process.merge(
          "published" => false,
          "questions" => remote_process["questions"].map { |question| question.merge("status" => nil) }
        )
      end

      def vocdoni_fixture(name)
        Decidim::Elections::Vocdoni::Engine.root.join("spec", "fixtures", "vocdoni", "#{name}.json").read
      end

      def json_response(body)
        { status: 200, body: body.is_a?(String) ? body : body.to_json, headers: json_headers }
      end

      # --- the eight calls of ARCHITECTURE §4c ---------------------------------

      def stub_add_members(body: vocdoni_fixture("members_added"))
        stub_request(:post, "#{api_url}/organizations/#{org_address}/members").to_return(json_response(body))
      end

      def stub_list_members
        stub_request(:get, "#{api_url}/organizations/#{org_address}/members")
          .with(query: { "page" => "1" })
          .to_return(json_response(vocdoni_fixture("organization_members")))
      end

      def stub_create_group
        stub_request(:post, "#{api_url}/organizations/#{org_address}/groups")
          .to_return(json_response(vocdoni_fixture("group_created")))
      end

      def stub_validate_group(gid = group_id, status: 200, body: "")
        stub_request(:post, "#{api_url}/organizations/#{org_address}/groups/#{gid}/validate")
          .to_return(status:, body: body.is_a?(String) ? body : body.to_json, headers: body.presence ? json_headers : {})
      end

      def stub_create_census
        stub_request(:post, "#{api_url}/census").to_return(json_response(vocdoni_fixture("census_created")))
      end

      def stub_publish_census(gid = group_id)
        stub_request(:post, "#{api_url}/census/#{census_id}/group/#{gid}/publish")
          .to_return(json_response(vocdoni_fixture("census_published")))
      end

      def stub_create_process(status: 200, body: vocdoni_fixture("process_created"))
        stub_request(:post, "#{api_url}/processes")
          .with { |request| captured[:process] = JSON.parse(request.body) }
          .to_return(status:, body: body.is_a?(String) ? body : body.to_json, headers: json_headers)
      end

      def stub_read_process(*responses)
        responses = [draft_process, remote_process] if responses.empty?

        stub_request(:get, "#{api_url}/processes/#{process_id}")
          .to_return(*responses.map { |response| json_response(response) })
      end

      def stub_publish_process
        stub_request(:post, "#{api_url}/processes/#{process_id}/publish")
          .to_return(json_response({ "jobId" => publish_job_id }))
      end

      def stub_job(job_id = publish_job_id, body: vocdoni_fixture("job_completed"))
        stub_request(:get, "#{api_url}/jobs/#{job_id}").to_return(json_response(body))
      end

      # The census part of the sequence for an election that already points at
      # a member group (nothing to import, nothing to group).
      def stub_census_sequence(gid = group_id)
        [stub_validate_group(gid), stub_create_census, stub_publish_census(gid)]
      end

      def stub_process_sequence
        [stub_create_process, stub_read_process, stub_publish_process, stub_job]
      end

      describe "the census guard" do
        let(:election) { create(:vocdoni_election, :with_questions) }

        it "never touches the API for an election that identifies nobody" do
          # Any request at all would raise: WebMock has nothing stubbed and net
          # connections are disabled.
          job.perform(election.id)

          election.reload
          expect(election.status).to eq("draft")
          expect(election).not_to be_on_chain
          expect(election.last_error_message).to include("census")
        end

        context "when the election has voters but no way to tell them apart" do
          let(:election) { create(:vocdoni_election, :with_questions, census_group_id: group_id) }

          it "is still refused" do
            job.perform(election.id)

            expect(election.reload.last_error_message).to include("census")
          end
        end

        context "when the census can identify a voter but holds none" do
          let(:election) { create(:vocdoni_election, :ready_to_publish, census_members_count: 0, census_group_id: nil) }

          it "is refused rather than published to an empty census" do
            job.perform(election.id)

            expect(election.reload.status).to eq("draft")
            expect(election.last_error_message).to include("census")
          end
        end
      end

      describe "a successful publication" do
        let!(:validate_request) { stub_validate_group }
        let!(:create_census_request) { stub_create_census }
        let!(:publish_census_request) { stub_publish_census }
        let!(:create_process_request) { stub_create_process }
        let!(:read_process_request) { stub_read_process }
        let!(:publish_process_request) { stub_publish_process }
        let!(:job_request) { stub_job }

        it "runs the census sequence before anything is written on chain" do
          job.perform(election.id)

          expect(validate_request).to have_been_requested
          expect(create_census_request).to have_been_requested
          expect(publish_census_request).to have_been_requested
          expect(create_process_request).to have_been_requested
          expect(publish_process_request).to have_been_requested
          expect(job_request).to have_been_requested
        end

        it "validates the group against the fields the census authenticates on" do
          job.perform(election.id)

          expect(
            a_request(:post, "#{api_url}/organizations/#{org_address}/groups/#{group_id}/validate")
              .with(body: { "authFields" => ["memberNumber"] })
          ).to have_been_made
        end

        it "creates the census for the configured organization" do
          job.perform(election.id)

          expect(
            a_request(:post, "#{api_url}/census").with(body: { "orgAddress" => org_address })
          ).to have_been_made
        end

        it "publishes the census out of the election's member group" do
          job.perform(election.id)

          expect(
            a_request(:post, "#{api_url}/census/#{census_id}/group/#{group_id}/publish")
              .with(body: { "authFields" => ["memberNumber"], "weighted" => false })
          ).to have_been_made
        end

        it "reads the process back exactly twice: before publishing and after" do
          job.perform(election.id)

          expect(read_process_request).to have_been_requested.twice
        end

        it "persists the process id, the chain id and the status" do
          job.perform(election.id)

          election.reload
          expect(election.vocdoni_process_id).to eq(process_id)
          expect(election.vocdoni_chain_id).to eq("vocdoni/LTS/1.2")
          expect(election.status).to eq("ready")
          expect(election).not_to be_editable
        end

        it "persists the per-question Vochain election id" do
          job.perform(election.id)

          question = election.reload.questions.first
          expect(question.vocdoni_question_id).to eq("6885f0c2c1a4e2f0b1d33a02")
          expect(question.vocdoni_upstream_id).to eq("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
          expect(question.vocdoni_status).to eq("ongoing")
        end

        it "persists the census size the publish reported" do
          election.update!(census_size: 0)

          job.perform(election.id)

          expect(election.reload.census_size).to eq(3)
        end

        it "clears any error left by a previous attempt" do
          election.update!(results_cache: { "error" => { "message" => "boom" } })

          job.perform(election.id)

          expect(election.reload.last_error).to be_nil
        end

        it "asks for a first tally" do
          expect { job.perform(election.id) }
            .to have_enqueued_job(Decidim::Elections::Vocdoni::SyncResultsJob).with(election.id)
        end
      end

      describe "the process payload" do
        before do
          stub_census_sequence
          stub_process_sequence

          job.perform(election.id)
        end

        it "sends language maps rather than bare strings" do
          expect(payload["title"]).to be_a(Hash)
          expect(payload["title"]).to have_key("default")
        end

        it "sends the census inline, pointing at the group Decidim owns" do
          expect(payload["census"]).to include(
            "authFields" => ["memberNumber"],
            "groupId" => group_id,
            "weighted" => false
          )
        end

        it "omits twoFaFields when the election is authentication-only" do
          expect(payload["census"]).not_to have_key("twoFaFields")
        end

        it "omits startDate when the election starts on publication" do
          expect(payload).not_to have_key("startDate")
        end

        it "sends a lowercase question type" do
          expect(payload["questions"].first["type"]).to eq("singlechoice")
        end

        it "sends 0-based choice values" do
          expect(payload["questions"].first["choices"].map { |choice| choice["value"] }).to eq([0, 1])
        end
      end

      # Regression: we used to send `paused: true` and `interruptible: true` for
      # a manual-start election, but the SaaS accepts a string `initialStatus`
      # instead (READY / PAUSED). The old boolean was silently ignored and the
      # election went out READY, opening for voting the moment it landed.
      describe "a manual-start process payload" do
        let(:election) do
          create(:vocdoni_election, :ready_to_publish,
                 census_members_count: 0, census_group_id: group_id,
                 manual_start: true, start_at: nil)
        end

        before do
          stub_census_sequence
          stub_process_sequence

          job.perform(election.id)
        end

        it "publishes the election in the PAUSED initial status" do
          expect(payload["initialStatus"]).to eq("PAUSED")
        end

        it "requests an interruptible process so the admin can pause it again" do
          # The SaaS no longer forces `interruptible` on a paused publish
          # (vocdoni/saas-backend#668), so this has to be sent explicitly.
          expect(payload["interruptible"]).to eq(true)
        end

        it "omits startDate: a manual-start election opens on the admin's action" do
          expect(payload).not_to have_key("startDate")
        end
      end

      describe "an auto-start process payload" do
        let(:election) do
          create(:vocdoni_election, :ready_to_publish,
                 census_members_count: 0, census_group_id: group_id,
                 manual_start: false, start_at: Time.zone.parse("2100-01-01 10:00"))
        end

        before do
          stub_census_sequence
          stub_process_sequence

          job.perform(election.id)
        end

        it "sends startDate and no initialStatus so the SaaS defaults to READY" do
          expect(payload["startDate"]).to be_present
          expect(payload).not_to have_key("initialStatus")
          expect(payload).not_to have_key("interruptible")
        end
      end

      # Regression: the SaaS doesn't populate `status` at the process root on a
      # multi-question process — it lives per-question. Reading `process["status"]`
      # alone made a manual-start election that landed PAUSED on chain report as
      # "ready" locally, so the Dashboard said "Voting open" the moment it
      # published. The rollup has to look at the questions.
      describe "when the API omits status at the process root" do
        let(:election) do
          create(:vocdoni_election, :ready_to_publish,
                 census_members_count: 0, census_group_id: group_id,
                 manual_start: true, start_at: nil)
        end

        let(:paused_process) do
          remote_process.merge(
            "status" => nil,
            "questions" => remote_process["questions"].map { |q| q.merge("status" => "PAUSED") }
          )
        end

        before do
          stub_census_sequence
          stub_create_process
          stub_read_process(draft_process, paused_process)
          stub_publish_process
          stub_job

          job.perform(election.id)
        end

        it "reads the election status off the questions when they agree" do
          expect(election.reload.status).to eq("paused")
          expect(election.questions.pluck(:vocdoni_status).uniq).to eq(["paused"])
        end
      end

      describe "a two-factor census" do
        let(:election) { create(:vocdoni_election, :ready_to_publish, :two_factor, census_members_count: 0, census_group_id: group_id) }

        before do
          stub_census_sequence
          stub_process_sequence
        end

        it "carries the two-factor fields through validation, census and process" do
          job.perform(election.id)

          expect(
            a_request(:post, "#{api_url}/organizations/#{org_address}/groups/#{group_id}/validate")
              .with(body: { "authFields" => ["memberNumber"], "twoFaFields" => ["email"] })
          ).to have_been_made

          expect(
            a_request(:post, "#{api_url}/census/#{census_id}/group/#{group_id}/publish")
              .with(body: { "authFields" => ["memberNumber"], "twoFaFields" => ["email"], "weighted" => false })
          ).to have_been_made

          expect(payload["census"]["twoFaFields"]).to eq(["email"])
        end
      end

      describe "when the census is built out of Decidim's own voters" do
        let!(:census_members) do
          [
            Decidim::Elections::Vocdoni::CensusMember.create!(
              election:, name: "Alice", surname: "Doe", email: "alice@example.org", member_number: "1001"
            ),
            Decidim::Elections::Vocdoni::CensusMember.create!(
              election:, name: "Bob", surname: "Roe", email: "bob@example.org", member_number: "1002"
            )
          ]
        end

        let!(:list_members_request) { stub_list_members }
        let!(:create_group_request) { stub_create_group }

        before do
          election.update!(census_group_id: nil)

          stub_add_members
          stub_census_sequence(new_group_id)
          stub_process_sequence
        end

        # `weight` is asserted as a *string* on purpose. Sending it as a JSON
        # number is answered with
        # `400 {"error":"invalid JSON request body: missing members","code":40004}`
        # — an error that names the wrong field entirely and cost a long
        # afternoon to attribute. Verified against staging; ARCHITECTURE §4c.
        it "pushes the voters into the organization memberbase" do
          job.perform(election.id)

          expect(
            a_request(:post, "#{api_url}/organizations/#{org_address}/members").with(
              body: {
                "members" => [
                  { "name" => "Alice", "surname" => "Doe", "email" => "alice@example.org", "memberNumber" => "1001", "weight" => "1" },
                  { "name" => "Bob", "surname" => "Roe", "email" => "bob@example.org", "memberNumber" => "1002", "weight" => "1" }
                ]
              }
            )
          ).to have_been_made
        end

        it "reads the memberbase back, because the import never returns ids" do
          job.perform(election.id)

          expect(list_members_request).to have_been_requested
        end

        it "groups exactly those members, under a title taken from the election" do
          job.perform(election.id)

          expect(
            a_request(:post, "#{api_url}/organizations/#{org_address}/groups").with do |request|
              body = JSON.parse(request.body)
              body["memberIds"] == %w(6a677022622d94e7c9a19301 6a677022622d94e7c9a19302) && body["title"].present?
            end
          ).to have_been_made
        end

        it "stores the group id without ever showing it to an admin" do
          job.perform(election.id)

          expect(election.reload.census_group_id).to eq(new_group_id)
        end

        it "writes each voter's upstream member id back, so a retry costs nothing" do
          job.perform(election.id)

          expect(census_members.map { |member| member.reload.vocdoni_member_id })
            .to eq(%w(6a677022622d94e7c9a19301 6a677022622d94e7c9a19302))
        end

        it "waits for an asynchronous import before grouping anybody" do
          stub_add_members(body: vocdoni_fixture("members_added_async"))
          import_job = stub_job("6885f1a3c1a4e2f0b1d33a30", body: vocdoni_fixture("job_members_completed"))

          job.perform(election.id)

          expect(import_job).to have_been_requested
        end

        it "refuses to go on when the memberbase rejected a voter" do
          stub_add_members(body: { "added" => 1, "errors" => ["line 2: duplicated memberNumber"] })

          # Does not re-raise: the API answered `errors` in a 2xx, so retrying
          # would push the same payloads and create fresh orphaned members
          # upstream on every attempt.
          expect { job.perform(election.id) }.not_to raise_error

          expect(create_group_request).not_to have_been_requested
          expect(election.reload.status).to eq("draft")
          expect(election.last_error_message).to match(/rejected 1 of 2 voters/)
        end
      end

      describe "when the group cannot authenticate its own members" do
        let!(:validate_request) do
          stub_validate_group(group_id, status: 400, body: vocdoni_fixture("group_validation_failed"))
        end

        let!(:create_census_request) { stub_create_census }

        it "stops before anything is written on chain" do
          job.perform(election.id)

          expect(validate_request).to have_been_requested
          expect(create_census_request).not_to have_been_requested
          expect(election.reload).not_to be_on_chain
        end

        it "does not raise: a retry would fail identically" do
          expect { job.perform(election.id) }.not_to raise_error
        end

        it "leaves the election editable so the admin can fix the census" do
          job.perform(election.id)

          expect(election.reload.status).to eq("draft")
          expect(election).to be_editable
        end

        it "keeps the member ids the admin has to act on" do
          job.perform(election.id)

          error = election.reload.last_error
          expect(error["step"]).to eq("validate_group")
          expect(error["code"]).to eq(40_037)
          expect(error["details"]["missingData"]).to eq(%w(6a677022622d94e7c9a19301 6a677022622d94e7c9a19302))
        end

        it "drops the empty lists the API pads its answer with" do
          job.perform(election.id)

          expect(election.reload.last_error["details"].keys).to eq(["missingData"])
        end

        it "never leaks the internal group id into the admin-facing message" do
          job.perform(election.id)

          message = election.reload.last_error_message
          expect(message).to include("invalid data provided")
          expect(message).not_to include(group_id)
          expect(message).to include("[census]")
        end
      end

      describe "idempotency" do
        context "when the election is already live on chain" do
          let(:election) { create(:vocdoni_election, :on_chain) }

          it "does nothing at all" do
            job.perform(election.id)

            expect(a_request(:post, "#{api_url}/processes")).not_to have_been_made
          end
        end

        context "when the publication was interrupted after the process was created" do
          let(:election) do
            create(:vocdoni_election, :ready_to_publish).tap do |record|
              record.update!(vocdoni_process_id: process_id, status: "publishing")
            end
          end

          before do
            stub_read_process
            stub_publish_process
            stub_job
          end

          it "resumes without rebuilding the census or creating a second process" do
            job.perform(election.id)

            expect(a_request(:post, "#{api_url}/census")).not_to have_been_made
            expect(a_request(:post, "#{api_url}/processes")).not_to have_been_made
            expect(election.reload.status).to eq("ready")
          end
        end

        context "when the process is already live upstream" do
          let(:election) do
            create(:vocdoni_election, :ready_to_publish).tap do |record|
              record.update!(vocdoni_process_id: process_id, status: "publishing")
            end
          end

          before { stub_read_process(remote_process) }

          it "does not publish a second time" do
            job.perform(election.id)

            expect(a_request(:post, "#{api_url}/processes/#{process_id}/publish")).not_to have_been_made
            expect(election.reload.status).to eq("ready")
          end
        end
      end

      describe "failure handling" do
        before do
          stub_census_sequence
          stub_create_process(status: 500, body: { "error" => "upstream exploded with key vsk_supersecret" })
        end

        it "puts the election back to draft and re-raises" do
          expect { job.perform(election.id) }.to raise_error(Decidim::Elections::Vocdoni::ApiError)

          expect(election.reload.status).to eq("draft")
        end

        it "records which step failed" do
          expect { job.perform(election.id) }.to raise_error(Decidim::Elections::Vocdoni::ApiError)

          expect(election.reload.last_error["step"]).to eq("create_process")
        end

        it "never writes a credential into the cached error" do
          expect { job.perform(election.id) }.to raise_error(Decidim::Elections::Vocdoni::ApiError)

          expect(election.reload.last_error_message).not_to include("vsk_supersecret")
          expect(election.last_error_message).to include("[REDACTED]")
        end
      end
    end
  end
end
end
