# frozen_string_literal: true

require "spec_helper"

# Every pin property here is enforced by Postgres (unique indexes, the
# append-only trigger, the row lock), so the examples run against the real
# test database rather than stubbing the model.
module Decidim
  module Elections
    module Vocdoni
      describe VoterCspController do
        let(:organization) { component.organization }
        let(:component) { create(:elections_component) }
        let(:user) { create(:user, :confirmed, organization:) }
        let(:election) { create(:election, :published, :ongoing, :with_internal_users_census, component:) }
        let!(:question) { create(:election_question, :with_response_options, :voting_enabled, election:) }

        let(:root) { Csp::Crypto.i2b(SecureRandom.random_number(Csp::Crypto::N - 1) + 1) }
        let(:root_id) { Csp::Keyring.id_for(root) }
        let(:roots_env) { "#{root_id}:#{root.unpack1("H*")}" }
        let(:pin_secret_hex) { SecureRandom.hex(32) }
        let(:pin_secret) { Csp::PinSecret.new([pin_secret_hex].pack("H*")) }
        let(:seed) { SecureRandom.hex(12) }
        let(:upstream_id) { SecureRandom.hex(32) }
        let(:census_root) { Csp::Crypto.public_key(Csp::Crypto.election_key(root, [seed].pack("H*"))).unpack1("H*") }
        let(:csp_state) { "verified" }
        let(:census_size) { 100 }
        let(:vocdoni_status) { "READY" }
        let!(:vocdoni_process) do
          create(:vocdoni_process, :published, election:, csp_state:, csp_root_id: root_id, pin_secret_id: pin_secret.id,
                                               census_size:, metadata: { "questions" => [questions_meta] })
        end
        let(:questions_meta) { { "decidim_question_id" => question.id, "vocdoni_upstream_id" => upstream_id, "vocdoni_status" => vocdoni_status } }
        let!(:csp_election) do
          create(:vocdoni_csp_election, process: vocdoni_process, decidim_question_id: question.id, seed:, census_root:, upstream_id:)
        end

        let(:address_hex) { SecureRandom.hex(20) }
        let(:address) { "0x#{address_hex}" }
        let(:upstream_bytes) { [upstream_id].pack("H*") }
        let(:nullifier_hex) { Csp::Crypto.nullifier([address_hex].pack("H*"), upstream_bytes).unpack1("H*") }
        let(:chain_url) { "https://chain.example.org/v2" }
        let(:csp_env) { { "VOCDONI_CSP_ROOTS" => roots_env, "VOCDONI_CSP_PIN_SECRET" => pin_secret_hex } }
        let(:json) { response.parsed_body }

        around do |example|
          old = %w(VOCDONI_CSP_ROOTS VOCDONI_CSP_PIN_SECRET).index_with { |k| ENV.fetch(k, nil) }
          example.run
        ensure
          old.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
          Vocdoni.reset_csp!
        end

        before do
          use_csp_env(csp_env)
          allow(Vocdoni).to receive(:chain_api_url).and_return(chain_url)
          request.env["decidim.current_organization"] = organization
          request.env["decidim.current_participatory_space"] = component.participatory_space
          request.env["decidim.current_component"] = component
          sign_in user
        end

        def use_csp_env(vars)
          %w(VOCDONI_CSP_ROOTS VOCDONI_CSP_PIN_SECRET).each { |k| ENV.delete(k) }
          vars.each { |k, v| ENV[k] = v }
          Vocdoni.reset_csp!
        end

        # Controller specs reuse one controller instance per example, and this
        # controller memoizes the voter, so each request gets a fresh one.
        def call(verb, action, **params)
          @controller = described_class.new
          allow(@controller).to receive_messages(current_participatory_space: component.participatory_space, current_component: component)
          public_send(verb, action, params: { component_id: component.id, election_id: election.id }.merge(params), as: :json)
          response
        end

        def sign(addr = address, question_id: question.id) = call(:post, :sign, questionId: question_id, address: addr)

        def csp_status = call(:get, :status)

        def confirm(question_id: question.id) = call(:post, :confirm, questionId: question_id)

        def digest_for(voter_key) = pin_secret.digest(voter_key)

        def recovered_root(signature_hex, addr_hex)
          bundle = Csp::Crypto.ca_bundle(upstream_bytes, [addr_hex].pack("H*"))
          Csp::Crypto.recover(bundle, [signature_hex].pack("H*")).unpack1("H*")
        end

        def stub_vote(nullifier, status: 200)
          stub_request(:get, "#{chain_url}/votes/#{nullifier}")
            .to_return(status:, body: { voteID: nullifier }.to_json, headers: { "Content-Type" => "application/json" })
        end

        def with_memory_cache
          allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
        end

        describe "POST sign" do
          it "signs the CA bundle with the question key and pins the address" do
            sign
            expect(response).to have_http_status(:ok)
            expect(json).to include("weight" => "01", "proofType" => "ECDSA")
            expect(recovered_root(json["signature"], address_hex)).to eq(census_root)

            pin = CspPin.sole
            expect(pin).to have_attributes(
              process_id: vocdoni_process.id, decidim_question_id: question.id, election_id: election.id,
              csp_root_id: root_id, seed:, address: address_hex, nullifier: nullifier_hex,
              voter_digest: digest_for("user:#{election.id}:#{user.id}")
            )
          end

          it "accepts an upper-case address and pins it lower-case" do
            sign("0x#{address_hex.upcase}")
            expect(response).to have_http_status(:ok)
            expect(CspPin.sole.address).to eq(address_hex)
          end

          it "re-signs the same address with the same signature and keeps one pin" do
            first = sign.parsed_body["signature"]
            second = sign.parsed_body["signature"]
            expect(response).to have_http_status(:ok)
            expect(second).to eq(first)
            expect(CspPin.count).to eq(1)
          end

          it "refuses a different address once pinned" do
            sign
            sign("0x#{SecureRandom.hex(20)}")
            expect(response).to have_http_status(:conflict)
            expect(json).to eq("error" => "address_pinned")
            expect(CspPin.sole.address).to eq(address_hex)
          end

          it "refuses an address another voter holds on the question" do
            sign
            sign_out user
            sign_in create(:user, :confirmed, organization:)
            sign
            expect(response).to have_http_status(:conflict)
            expect(json).to eq("error" => "address_taken")
            expect(CspPin.count).to eq(1)
          end

          it "refuses any address once the pin is purged" do
            sign
            CspPin.sole.update!(address: nil, nullifier: nil, purged_at: Time.current)
            sign
            expect(response).to have_http_status(:conflict)
            expect(json).to eq("error" => "address_pinned")
          end

          it "refuses a malformed address" do
            sign("0x1234")
            expect(response).to have_http_status(:unprocessable_content)
            expect(json).to eq("error" => "invalid_address")
            expect(CspPin.count).to eq(0)
          end

          shared_examples "a closed question" do
            it "answers 409 question_closed and pins nothing" do
              sign
              expect(response).to have_http_status(:conflict)
              expect(json).to eq("error" => "question_closed")
              expect(CspPin.count).to eq(0)
            end
          end

          context "when the roots are not verified yet" do
            let(:csp_state) { nil }

            it_behaves_like "a closed question"
          end

          context "when the roots are compromised" do
            let(:csp_state) { "compromised" }

            it_behaves_like "a closed question"
          end

          context "when a chain check finds another root on a verified process" do
            before do
              other = Csp::Crypto.public_key(SecureRandom.random_number(Csp::Crypto::N - 1) + 1).unpack1("H*")
              stub_request(:get, "#{chain_url}/elections/#{upstream_id}")
                .to_return(json_response(chain_election(csp_election, census_root: other)))
              CspVerifier.new(vocdoni_process).recheck!
            rescue Csp::Compromised
              nil # the process is now compromised; signing must refuse
            end

            it_behaves_like "a closed question"
          end

          context "when the chain election is not READY" do
            let(:vocdoni_status) { "PAUSED" }

            it_behaves_like "a closed question"
          end

          context "when the question has no upstream id yet" do
            let!(:csp_election) do
              create(:vocdoni_csp_election, process: vocdoni_process, decidim_question_id: question.id, seed:, census_root:, upstream_id: nil)
            end

            it_behaves_like "a closed question"
          end

          context "when the question has no CSP election" do
            let!(:csp_election) { nil }

            it_behaves_like "a closed question"
          end

          context "when a per-question election has not opened the question" do
            let(:election) { create(:election, :published, :ongoing, :per_question, :with_internal_users_census, component:) }
            let!(:question) { create(:election_question, :with_response_options, election:) }

            it_behaves_like "a closed question"
          end

          context "when the election has ended" do
            let(:election) { create(:election, :published, :finished, :with_internal_users_census, component:) }

            it "answers 403 not_allowed" do
              sign
              expect(response).to have_http_status(:forbidden)
              expect(CspPin.count).to eq(0)
            end
          end

          context "with a token_csv census" do
            let(:election) { create(:election, :published, :ongoing, :with_token_csv_census, component:) }
            let(:voter) { election.voters.first }

            it "answers 403 not_in_census without a census session" do
              sign_out user
              sign
              expect(response).to have_http_status(:forbidden)
              expect(json).to eq("error" => "not_in_census")
            end

            it "keys the pin on the census row of an authenticated voter" do
              sign_out user
              session[:session_attributes] = { "email" => voter.data["email"], "token" => voter.data["token"] }
              sign
              expect(response).to have_http_status(:ok)
              expect(CspPin.sole.voter_digest).to eq(digest_for("row:#{election.id}:#{voter.id}"))
            end
          end

          context "with an internal_users census the user is not in" do
            let(:election) do
              create(:election, :published, :ongoing, component:, census_manifest: "internal_users",
                                                      census_settings: { "authorization_handlers" => { "id_documents" => {} } })
            end

            it "answers 403 not_in_census" do
              sign
              expect(response).to have_http_status(:forbidden)
              expect(json).to eq("error" => "not_in_census")
            end
          end

          it "requires a CSRF token" do
            ActionController::Base.allow_forgery_protection = true
            expect { sign }.to raise_error(ActionController::InvalidAuthenticityToken)
            expect(CspPin.count).to eq(0)
          ensure
            ActionController::Base.allow_forgery_protection = false
          end

          describe "CSP configuration failures" do
            it "answers 500 pin_secret_mismatch when the process recorded another pin secret" do
              vocdoni_process.update!(pin_secret_id: "0" * 16)
              sign
              expect(response).to have_http_status(:internal_server_error)
              expect(json).to eq("error" => "pin_secret_mismatch")
              expect(CspPin.count).to eq(0)
            end

            it "answers 500 csp_root_missing for a root id the keyring lacks, without falling back" do
              vocdoni_process.update!(csp_root_id: "0" * 16)
              sign
              expect(response).to have_http_status(:internal_server_error)
              expect(json).to eq("error" => "csp_root_missing")
              expect(CspPin.count).to eq(0)
            end

            it "answers 500 csp_root_missing on sign and status when no pin secret is set" do
              use_csp_env("VOCDONI_CSP_ROOTS" => roots_env)
              sign
              expect(response).to have_http_status(:internal_server_error)
              expect(json).to eq("error" => "csp_root_missing")
              csp_status
              expect(response).to have_http_status(:internal_server_error)
              expect(json).to eq("error" => "csp_root_missing")
            end

            it "answers 500 csp_root_missing when no root is set" do
              use_csp_env("VOCDONI_CSP_PIN_SECRET" => pin_secret_hex)
              sign
              expect(response).to have_http_status(:internal_server_error)
              expect(json).to eq("error" => "csp_root_missing")
            end

            it "answers 500 csp_trigger_missing before computing any digest when the pins guard is off" do
              ActiveRecord::Base.connection.execute("ALTER TABLE decidim_vocdoni_csp_pins DISABLE TRIGGER decidim_vocdoni_csp_pins_guard")
              allow(Csp::PinSecret).to receive(:voter_key).and_call_original
              sign
              expect(response).to have_http_status(:internal_server_error)
              expect(json).to eq("error" => "csp_trigger_missing")
              expect(Csp::PinSecret).not_to have_received(:voter_key)
              expect(CspPin.count).to eq(0)
            end

            it "logs the failure with ids only" do
              vocdoni_process.update!(csp_root_id: "0" * 16)
              allow(Rails.logger).to receive(:error)
              sign
              expect(Rails.logger).to have_received(:error).with(satisfy do |line|
                data = JSON.parse(line)
                data["event"] == "csp.failure" && data["code"] == "csp_root_missing" && data["csp_root_id"] == "0" * 16 &&
                  line.exclude?(root.unpack1("H*")) && line.exclude?(pin_secret_hex)
              end)
            end
          end

          it "keeps the digest, the pin and the recorded root when a newer root joins the keyring" do
            first = sign.parsed_body["signature"]
            digest = CspPin.sole.voter_digest

            newer = Csp::Crypto.i2b(SecureRandom.random_number(Csp::Crypto::N - 1) + 1)
            use_csp_env(csp_env.merge("VOCDONI_CSP_ROOTS" => "#{roots_env},#{Csp::Keyring.id_for(newer)}:#{newer.unpack1("H*")}"))
            expect(Vocdoni.csp_keyring.newest_id).not_to eq(root_id)

            expect(sign.parsed_body["signature"]).to eq(first)
            sign("0x#{SecureRandom.hex(20)}")
            expect(response).to have_http_status(:conflict)
            expect(json).to eq("error" => "address_pinned")
            expect(CspPin.sole.voter_digest).to eq(digest)
            expect(CspPin.sole.csp_root_id).to eq(root_id)
          end

          describe "census growth" do
            let(:census_size) { 1 }

            before do
              with_memory_cache
              create_list(:user, 2, :confirmed, organization:)
            end

            it "enqueues ResizeCensusJob once when the roster exceeds the declared size" do
              expect do
                sign
                sign_out user
                sign_in create(:user, :confirmed, organization:)
                sign("0x#{SecureRandom.hex(20)}")
              end.to have_enqueued_job(ResizeCensusJob).with(vocdoni_process.id).exactly(:once)
              expect(CspPin.count).to eq(2)
            end

            context "when the roster fits" do
              let(:census_size) { 100 }

              it "does not enqueue it" do
                expect { sign }.not_to have_enqueued_job(ResizeCensusJob)
              end
            end
          end

          it "answers 429 to the fourth sign in a minute" do
            with_memory_cache
            3.times do
              sign
              expect(response).to have_http_status(:ok)
            end
            sign
            expect(response).to have_http_status(:too_many_requests)
            expect(json).to eq("error" => "rate_limited")
          end

          describe "logging" do
            let(:log) { StringIO.new }
            let(:logger) { ActiveSupport::Logger.new(log).tap { |l| l.level = :debug } }

            around do |example|
              Rails.logger.broadcast_to(logger)
              example.run
            ensure
              Rails.logger.stop_broadcasting_to(logger)
            end

            it "writes one csp.sign line per outcome with a digest prefix only" do
              signature = sign.parsed_body["signature"]
              sign("0x#{SecureRandom.hex(20)}")
              stub_vote(nullifier_hex)
              csp_status
              confirm

              lines = log.string.lines.grep(/"event":"csp\.sign"/).map { |l| JSON.parse(l[/\{.*\}/]) }
              expect(lines.pluck("outcome")).to eq(%w(issued address_pinned))
              expect(lines.pluck("voter_digest").uniq).to eq([CspPin.sole.voter_digest[0, 16]])

              text = log.string.downcase
              expect(text).not_to include(address_hex)
              expect(text).not_to include(nullifier_hex)
              expect(text).not_to include(signature)
            end

            it "filters the address from the request parameters log" do
              sign
              expect(log.string).to include("Parameters:")
              expect(log.string).to match(/"address" ?=> ?"\[FILTERED\]"/)
              expect(log.string.downcase).not_to include(address_hex)
            end
          end
        end

        describe "GET status" do
          it "describes each question before any pin" do
            csp_status
            expect(response).to have_http_status(:ok)
            expect(json["questions"]).to eq([{ "questionId" => question.id, "votingEnabled" => true, "canVote" => true,
                                               "pinnedAddress" => nil, "nullifier" => nil, "hasVoted" => false }])
          end

          it "shows the pin and confirms a vote the chain has" do
            sign
            vote = stub_vote(nullifier_hex)
            csp_status
            expect(json["questions"].sole).to include("pinnedAddress" => address, "nullifier" => nullifier_hex,
                                                      "canVote" => true, "hasVoted" => true)
            expect(vote).to have_been_requested.once
            expect(CspPin.sole.vote_confirmed_at).to be_present
          end

          it "re-checks an unconfirmed pin at most once per 30 seconds" do
            with_memory_cache
            sign
            vote = stub_vote(nullifier_hex, status: 404)
            2.times { csp_status }
            expect(json["questions"].sole["hasVoted"]).to be(false)
            expect(vote).to have_been_requested.once
            travel 31.seconds
            csp_status
            expect(vote).to have_been_requested.twice
          end

          it "still answers when the chain is down" do
            sign
            stub_request(:get, "#{chain_url}/votes/#{nullifier_hex}").to_timeout
            csp_status
            expect(response).to have_http_status(:ok)
            expect(json["questions"].sole["hasVoted"]).to be(false)
          end

          it "reports a purged pin as unable to vote" do
            sign
            CspPin.sole.update!(address: nil, nullifier: nil, purged_at: Time.current)
            csp_status
            expect(json["questions"].sole).to include("pinnedAddress" => nil, "canVote" => false)
          end

          it "answers 403 not_in_census to a voter outside the census" do
            sign_out user
            csp_status
            expect(response).to have_http_status(:forbidden)
          end
        end

        describe "POST confirm" do
          it "records the vote once the chain has it" do
            sign
            stub_vote(nullifier_hex)
            confirm
            expect(response).to have_http_status(:ok)
            expect(json).to include("questionId" => question.id, "hasVoted" => true)
            expect(CspPin.sole.vote_confirmed_at).to be_present
          end

          it "leaves the pin unconfirmed while the chain has no vote" do
            sign
            stub_vote(nullifier_hex, status: 404)
            confirm
            expect(response).to have_http_status(:ok)
            expect(json["hasVoted"]).to be(false)
            expect(CspPin.sole.vote_confirmed_at).to be_nil
          end

          it "keeps the first confirmation time" do
            sign
            stub_vote(nullifier_hex)
            confirm
            first = CspPin.sole.vote_confirmed_at
            travel 1.minute
            confirm
            expect(response).to have_http_status(:ok)
            expect(CspPin.sole.vote_confirmed_at).to eq(first)
          end

          it "answers 503 when the chain is unavailable" do
            sign
            stub_request(:get, "#{chain_url}/votes/#{nullifier_hex}").to_return(status: 502)
            confirm
            expect(response).to have_http_status(:service_unavailable)
            expect(json).to eq("error" => "chain_unavailable")
          end

          it "answers 404 without a pin" do
            confirm
            expect(response).to have_http_status(:not_found)
            expect(json).to eq("error" => "pin_not_found")
          end
        end

        it "throttles /csp/ requests to 120 a minute per IP" do
          throttle = Rack::Attack.throttles.fetch("vocdoni/csp/ip")
          expect([throttle.limit, throttle.period]).to eq([120, 60])
          request_for = ->(path) { Rack::Attack::Request.new(Rack::MockRequest.env_for(path, "REMOTE_ADDR" => "203.0.113.9")) }
          expect(throttle.block.call(request_for.call("/processes/p/f/1/elections/2/csp/sign"))).to eq("203.0.113.9")
          expect(throttle.block.call(request_for.call("/processes/p/f/1/elections/2/votes"))).to be_nil
        end

        context "when the election is not Vocdoni-backed" do
          let!(:vocdoni_process) { nil }
          let!(:csp_election) { nil }

          it "answers 404" do
            csp_status
            expect(response).to have_http_status(:not_found)
          end
        end
      end

      # Two sign requests for one voter race through the whole stack, each on
      # its own database connection, with commits outside any test transaction.
      describe VoterCspController, "under concurrency" do
        include_context "with concurrency and csp pins"

        let(:organization) { component.organization }
        let(:component) { create(:elections_component) }
        let(:user) { create(:user, :confirmed, organization:) }
        let(:election) { create(:election, :published, :ongoing, :with_internal_users_census, component:) }
        let(:question) { create(:election_question, :with_response_options, :voting_enabled, election:) }
        let(:root) { Csp::Crypto.i2b(SecureRandom.random_number(Csp::Crypto::N - 1) + 1) }
        let(:root_id) { Csp::Keyring.id_for(root) }
        let(:pin_secret_hex) { SecureRandom.hex(32) }
        let(:seed) { SecureRandom.hex(12) }
        let(:upstream_id) { SecureRandom.hex(32) }
        let(:sign_path) { Decidim::EngineRouter.main_proxy(component).election_csp_sign_path(election) }

        around do |example|
          old = %w(VOCDONI_CSP_ROOTS VOCDONI_CSP_PIN_SECRET).index_with { |k| ENV.fetch(k, nil) }
          ENV["VOCDONI_CSP_ROOTS"] = "#{root_id}:#{root.unpack1("H*")}"
          ENV["VOCDONI_CSP_PIN_SECRET"] = pin_secret_hex
          Vocdoni.reset_csp!
          example.run
        ensure
          old.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
          Vocdoni.reset_csp!
        end

        before do
          metadata = { "questions" => [{ "decidim_question_id" => question.id, "vocdoni_status" => "READY" }] }
          vocdoni_process = create(:vocdoni_process, :published, election:, csp_state: "verified", csp_root_id: root_id, census_size: 100,
                                                                 pin_secret_id: Csp::PinSecret.load(pin_secret_hex).id, metadata:)
          census_root = Csp::Crypto.public_key(Csp::Crypto.election_key(root, [seed].pack("H*"))).unpack1("H*")
          create(:vocdoni_csp_election, process: vocdoni_process, decidim_question_id: question.id, seed:, census_root:, upstream_id:)
          allow_any_instance_of(described_class).to receive(:voter_uid).and_return(user.to_global_id.to_s) # rubocop:disable RSpec/AnyInstance
        end

        it "pins exactly one address and refuses the other" do
          barrier = Concurrent::CyclicBarrier.new(2)
          # Both requests pass the pin lookup before either inserts.
          allow_any_instance_of(described_class).to receive(:signing_root!).and_wrap_original do |method, *args| # rubocop:disable RSpec/AnyInstance
            barrier.wait(5)
            method.call(*args)
          end
          inserts = Concurrent::Array.new
          allow_any_instance_of(described_class).to receive(:create_pin).and_wrap_original do |method, *args| # rubocop:disable RSpec/AnyInstance
            method.call(*args).tap { |pin| inserts << pin.present? }
          end

          addresses = Array.new(2) { SecureRandom.hex(20) }
          results = addresses.map do |addr|
            Thread.new do
              ActiveRecord::Base.connection_pool.with_connection do
                body = { questionId: question.id, address: "0x#{addr}" }.to_json
                Rack::MockRequest.new(Rails.application).post(
                  sign_path, { "HTTP_HOST" => organization.host, "CONTENT_TYPE" => "application/json", :input => body }
                )
              end
            end
          end.map(&:value)

          # Both tried to insert; the loser hit the unique index, re-read and
          # found the winner's pin.
          expect(inserts.sort_by { |ok| ok ? 1 : 0 }).to eq([false, true])
          expect(results.map(&:status).sort).to eq([200, 409])
          expect(JSON.parse(results.find { |r| r.status == 409 }.body)).to eq("error" => "address_pinned")
          pin = CspPin.sole
          winner = addresses[results.index { |r| r.status == 200 }]
          expect(pin.address).to eq(winner)
        end
      end
    end
  end
end
