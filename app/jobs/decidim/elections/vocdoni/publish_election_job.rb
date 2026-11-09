# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Enqueued from a subscriber to
      # `decidim.elections.admin.publish_election:after` (upstream event added
      # by vocdoni/decidim#2) whenever an election that has opted in to
      # Vocdoni is published from the Decidim admin.
      #
      # Decidim is the census provider (external CSP) of the process: the SaaS
      # gets the declared census size and one public census root per question,
      # derived from a root only Decidim holds, and never a voter. The job lands
      # the process on chain:
      #
      #   check the CSP setup → declare the census size → record the root and
      #   pin secret ids → create the process → derive and store the roots per
      #   question → publish → persist the ids → verify the chain holds the roots.
      #
      # The Vocdoni-side state (process id, chain id, per-question upstream ids,
      # csp elections) is written into the {Process} sidecar row that
      # {Admin::UpdateElectionSecurity} bootstrapped in state `pending` when
      # the admin ticked "Enable Vocdoni" on the Security tab.
      # `Decidim::Elections::Election` and its associated tables are read-only
      # from this job's point of view.
      #
      # Only handles elections that opted in — that is, those whose sidecar is
      # already present when the publish notification fires. The subscriber
      # filters on the same predicate, but the job double-checks so a manually
      # enqueued run cannot publish a non-Vocdoni election.
      class PublishElectionJob < ApplicationJob
        queue_as :vocdoni

        # Only transient failures (network flap, 5xx, 429) are retried — a
        # permanent rejection (4xx or a 2xx with `errors` in the body) fails
        # identically on retry.
        retry_on Decidim::Elections::Vocdoni::ApiError, wait: :polynomially_longer, attempts: 3

        def perform(election_id, scheduled_start_at = nil) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          return unless bootstrap!(election_id)
          return if published_upstream?
          # Someone else — the manual-start subscriber or a previous run —
          # is already pushing this election. Skipping avoids duplicate SaaS
          # resources on manual+scheduled overlap.
          return if process.publishing?

          # Self-invalidation for scheduled pushes: if the admin rescheduled
          # start_at after this job was enqueued, the model's
          # `after_update_commit` (see the reschedule_push_on_start_at_change
          # initializer) enqueued a fresh job for the new timestamp. This
          # stale copy silently no-ops. Compared at second precision — that
          # is the precision an admin can control from the form, and it
          # sidesteps a microsecond diff between the model's Time and the
          # ActiveJob-serialized Time we get back here.
          if scheduled_start_at.present?
            expected_at = scheduled_start_at.respond_to?(:to_i) ? scheduled_start_at : Time.zone.parse(scheduled_start_at.to_s)
            return if election.start_at.nil? || election.start_at.to_i != expected_at.to_i
          end

          # Roots, pin secret and pins trigger, before any SaaS call.
          @step = "csp_ready"
          Decidim::Elections::Vocdoni.csp_ready!
          Decidim::Elections::Vocdoni.validate_configuration!

          process.update!(state: "publishing")

          declare_census!
          record_csp_ids!
          ensure_process_created!
          ensure_csp_elections!
          ensure_process_published!
          persist_process_metadata!

          process.update!(state: "published")
          verify_roots!

          # Kick off the on-chain state monitor so the sidecar keeps mirroring
          # the SaaS while voting is open.
          Decidim::Elections::Vocdoni::SyncProcessJob.perform_later(election.id)
        rescue Csp::Compromised
          # Recorded by the verifier; retrying cannot change what the chain holds.
          Decidim::Elections::Vocdoni::SyncProcessJob.perform_later(election.id)
        rescue Decidim::Elections::Vocdoni::ApiError => e
          record_step_failure!(e)
          Decidim::Elections::Vocdoni::SyncProcessJob.perform_later(election.id) if process.vocdoni_process_id.present?
          raise if e.transient?
        rescue Csp::IntegrityError => e
          # The SaaS answered ids that do not fit this process; a retry gets
          # the same answer.
          record_step_failure!(e)
          Decidim::Elections::Vocdoni::SyncProcessJob.perform_later(election.id) if process.vocdoni_process_id.present?
        rescue StandardError => e
          record_step_failure!(e)
          Decidim::Elections::Vocdoni::SyncProcessJob.perform_later(election.id) if process.vocdoni_process_id.present?
          raise
        end

        private

        attr_reader :process

        def vocdoni_backed?
          election.vocdoni_process.present?
        end

        def published_upstream?
          process.vocdoni_process_id.present? && process.published?
        end

        # Rebinds `@election` because `ApplicationJob`'s own `attr_reader
        # :election` is protected and shared across attempts.
        def bootstrap!(election_id)
          @election = Decidim::Elections::Election.find_by(id: election_id)
          return false if election.blank?
          return false unless vocdoni_backed?

          @process = election.vocdoni_process
          true
        end

        # SaaS 400s carry `{"error":..., "code":..., "data":{...}}` as JSON;
        # Faraday's json middleware only parses it into a Hash when the
        # response's `Content-Type` matches `/\bjson$/`, so anything with a
        # `; charset=utf-8` suffix (or a proxy that stripped it) leaves us
        # with the raw body as a String. Fall back to a manual JSON parse
        # so the structured `data` reaches the admin either way.
        def extract_error_data(error)
          return nil unless error.respond_to?(:body)

          body = error.try(:body)
          if body.is_a?(String)
            body = begin
              JSON.parse(body)
            rescue StandardError
              nil
            end
          end
          return nil unless body.is_a?(Hash)

          body["data"]
        end

        def record_step_failure!(error)
          message = redact(error.message)
          body_data = extract_error_data(error)
          error_code = error.respond_to?(:code) ? error.try(:code) : nil

          process.record_failure!(message, step: @step, code: error_code, data: body_data)
        end

        # ---------------------------------------------------------------------
        # Census
        # ---------------------------------------------------------------------

        # The census stays in Decidim; the SaaS only gets its declared size,
        # which the chain enforces as maxCensusSize. Set once: a retry keeps
        # the size the first attempt declared.
        def declare_census!
          @step = "declare_census"
          @roster = election.census.count(election).to_i
          raise Decidim::Elections::Vocdoni::ApiError.new("This election's census resolves to zero voters (empty census)", transient: false) if @roster.zero?
          return if process.census_size.present?

          process.update!(census_size: Decidim::Elections::Vocdoni.declared_census_size(election, @roster))
        end

        # The root and pin secret a process signs with are fixed before the
        # process exists upstream and never rewritten, so every signature of
        # this election comes from the same derived keys and the same digests.
        def record_csp_ids!
          @step = "record_csp_ids"
          keyring = Decidim::Elections::Vocdoni.csp_keyring
          raise Csp::RootMissing, "VOCDONI_CSP_ROOTS is not set" if keyring.nil? || keyring.ids.empty?

          keyring.assert_prod_safe!(chain.chain_info.to_h["chainId"])
          return if process.csp_root_id.present? && process.pin_secret_id.present?

          process.update!(csp_root_id: process.csp_root_id.presence || keyring.newest_id,
                          pin_secret_id: process.pin_secret_id.presence || Decidim::Elections::Vocdoni.csp_pin_secret.id)
        end

        # ---------------------------------------------------------------------
        # Process
        # ---------------------------------------------------------------------

        def ensure_process_created!
          return if process.vocdoni_process_id.present?

          @step = "create_process"
          response = client.elections.create(process_payload).to_h
          process_id = response["processId"].presence
          raise Decidim::Elections::Vocdoni::ApiError.new("POST /processes returned no processId", body: response, transient: false) if process_id.blank?

          process.update!(vocdoni_process_id: process_id)
        end

        # One csp election per Decidim question, seeded by the SaaS question id
        # the draft answered, with the census root derived from the recorded
        # root. The roots go to the draft before it is published; the chain
        # check after publish catches a draft that changed in between.
        def ensure_csp_elections!
          @step = "csp_elections"
          remote = remote_process
          by_question = remote_questions_by_decidim_id(remote)
          root = Decidim::Elections::Vocdoni.csp_keyring.fetch(process.csp_root_id)

          rows = election.questions.map do |question|
            upstream = by_question[question.id]
            raise Csp::IntegrityError, "question #{question.id} is missing from the SaaS process" if upstream.blank?

            csp_election_for(question, remote_question_id(upstream), root)
          end
          return if live_upstream?(remote)

          client.elections.set_external_csp_roots(process.vocdoni_process_id, rows.to_h { |ce| [ce.seed, "0x#{ce.census_root}"] })
        end

        def csp_election_for(question, seed, root)
          raise Csp::IntegrityError, "SaaS id of question #{question.id} is not a 12-byte hex id" unless seed.match?(CspElection::SEED_FORMAT)

          census_root = Csp::Crypto.public_key(Csp::Crypto.election_key(root, [seed].pack("H*"))).unpack1("H*")
          ce = CspElection.find_or_create_by!(process:, decidim_question_id: question.id) do |row|
            row.seed = seed
            row.census_root = census_root
          end
          raise Csp::IntegrityError, "SaaS id of question #{question.id} differs from the recorded seed" unless ce.seed == seed
          raise Csp::IntegrityError, "census root of question #{question.id} differs from the recorded one" unless ce.census_root == census_root

          ce
        end

        def ensure_process_published!
          remote = remote_process
          return if live_upstream?(remote)

          @step = "publish_process"
          response = client.elections.publish(process.vocdoni_process_id).to_h
          await_job!(response["jobId"])
          @remote_process = nil
        end

        def persist_process_metadata!
          @step = "persist"
          remote = remote_process
          by_question = remote_questions_by_decidim_id(remote)

          questions_meta = election.questions.map do |question|
            upstream = by_question[question.id]
            next nil if upstream.blank?

            bind_upstream_id!(question, upstream["upstreamId"])
            {
              "decidim_question_id" => question.id,
              "vocdoni_question_id" => remote_question_id(upstream).presence,
              "vocdoni_upstream_id" => upstream["upstreamId"].to_s.presence,
              "vocdoni_status" => upstream["status"].to_s.presence
            }
          end.compact

          # census_size is the size Decidim declared and confirms on chain;
          # the SaaS echo of it is never copied back.
          process.update!(
            chain_id: remote["chainId"].to_s.presence,
            vocdoni_upstream_id: remote["upstreamId"].to_s.presence,
            metadata: process.metadata.merge("questions" => questions_meta)
          )
        end

        def bind_upstream_id!(question, upstream_id)
          return if upstream_id.blank?

          process.csp_elections.find_by(decidim_question_id: question.id)&.bind_upstream_id!(upstream_id)
        end

        # Signing stays off until the chain is shown to hold the derived roots.
        # A chain that cannot be reached leaves csp_state nil; the sync job
        # retries on its next tick.
        def verify_roots!
          @step = "verify_roots"
          CspVerifier.new(process, chain:).verify_roots!
        rescue Decidim::Elections::Vocdoni::ApiError => e
          raise unless e.transient?

          Rails.logger.warn({ event: "csp.verify_deferred", process_id: process.id, error: redact(e.message) }.to_json)
        end

        def chain
          @chain ||= ChainClient.new
        end

        def remote_process
          @remote_process ||= client.elections.get(process.vocdoni_process_id).to_h
        end

        def live_upstream?(remote)
          return true if remote["published"] == true

          %w(READY ONGOING ENDED RESULTS PAUSED).include?(remote["status"].to_s)
        end

        # SaaS questions keyed by the Decidim question id carried in their
        # metadata, never by position.
        def remote_questions_by_decidim_id(remote)
          Array(remote["questions"]).grep(Hash).each_with_object({}) do |upstream, map|
            id = upstream.dig("metadata", "decidimQuestionId").to_s
            map[id.to_i] = upstream if id.match?(/\A\d+\z/)
          end
        end

        def remote_question_id(upstream)
          (upstream["id"] || upstream["questionId"]).to_s.downcase
        end

        # ---------------------------------------------------------------------
        # Payload
        # ---------------------------------------------------------------------

        def process_payload
          payload = {
            "orgAddress" => org_address,
            "title" => localize(election.title),
            "description" => localize(election.description) || localize(election.title),
            "endDate" => election.end_at,
            "census" => census_payload,
            "questions" => election.questions.map { |question| question_payload(question) }
          }

          payload["startDate"] = election.start_at if election.start_at.present?

          payload
        end

        # Decidim holds the census: the SaaS gets the declared size and where
        # voters are, and nothing about members, groups or auth fields.
        def census_payload
          { "externalCsp" => { "size" => process.census_size, "censusUri" => election_url } }
        end

        def election_url
          Decidim::ResourceLocatorPresenter.new(election).url
        end

        # Upstream Decidim uses `single_option` / `multiple_option`; the SaaS
        # accepts lowercase `singlechoice` / `multichoice` and rejects
        # anything else with code 40037.
        QUESTION_TYPE_MAP = {
          "single_option" => "singlechoice",
          "multiple_option" => "multichoice"
        }.freeze

        def question_payload(question)
          type = QUESTION_TYPE_MAP.fetch(question.question_type.to_s, question.question_type.to_s)

          payload = {
            "title" => localize(question.body),
            "type" => type,
            "choices" => question.response_options.order(:id).map.with_index do |option, idx|
              { "title" => localize(option.body), "value" => idx }
            end,
            "secretUntilTheEnd" => secret_until_the_end?,
            # Maps the SaaS question, and so its seed, back to this question.
            "metadata" => { "decidimQuestionId" => question.id.to_s }
          }

          description = localize(question.description)
          payload["description"] = description if description.present?

          # Only multichoice carries typeSetup: singlechoice ignores it, ranked
          # and cumulative reject it. `uniqueChoices` is rejected because each
          # choice is an independent 0/1 field, so a duplicate is impossible.
          if type == "multichoice"
            max = question.max_choices.to_i
            payload["typeSetup"] = {
              "maxChoices" => [max, 1].max,
              "minChoices" => question.mandatory? ? 1 : 0
            }
          end

          payload
        end

        # ---------------------------------------------------------------------
        # Config
        # ---------------------------------------------------------------------

        # Ballots are encrypted on chain unless the election shows live results:
        # with `after_end` and `per_question` nobody may see partial tallies
        # before the question (or election) closes.
        def secret_until_the_end?
          election.results_availability.to_s != "real_time"
        end

        def org_address
          Decidim::Elections::Vocdoni.org_address
        end

        def default_locale
          @default_locale ||= (election.organization&.default_locale || Decidim.default_locale || I18n.default_locale).to_s
        end
      end
    end
  end
end
