# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Runs when voting starts on an election that has opted in to Vocdoni:
      # scheduled for `start_at` by the subscriber to
      # `decidim.elections.admin.publish_election:after` (upstream event added
      # by vocdoni/decidim#2), or enqueued when the admin clicks Start on a
      # manual-start election. The census size it declares is the census at
      # that moment plus room for late joiners.
      #
      # Talks to the Vocdoni SaaS API through the shared {ApiClient} and lands
      # the process on chain:
      #
      #   draw the attestation secrets → create process (attested census) →
      #   publish process → persist ids on the {Process} sidecar.
      #
      # No roster leaves Decidim: the process declares the election's signer and a maximum census
      # size, and the booth attests each voter Decidim's census admits.
      #
      # The Vocdoni-side state (process id, chain id, per-question
      # upstream ids) is written into the {Process} sidecar row that
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

        # Only transient failures (network flap, 5xx, 429) are retried: a permanent rejection (4xx
        # or a 2xx with `errors` in the body) fails identically on retry.
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

          Decidim::Elections::Vocdoni.validate_configuration!

          process.update!(state: "publishing")

          prepare_census!
          ensure_process_created!
          ensure_process_published!
          persist_process_metadata!

          process.update!(state: "published")

          # Kick off the on-chain state monitor so the sidecar keeps mirroring
          # the SaaS while voting is open.
          Decidim::Elections::Vocdoni::SyncProcessJob.perform_later(election.id)
          catch_up_questions!
        rescue Decidim::Elections::Vocdoni::ApiError => e
          record_step_failure!(e)
          Decidim::Elections::Vocdoni::SyncProcessJob.perform_later(election.id) if process.vocdoni_process_id.present?
          raise if e.transient?
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

        # The census pushes no roster: the election's signer vouches for each voter at booth time.
        def prepare_census!
          ensure_census_ready!
          check_two_fa_fields!
          process.ensure_attestation_secrets!
        end

        # SaaS 400s carry `{"error":..., "code":..., "data":{...}}` as JSON;
        # Faraday's json middleware only parses it into a Hash when the
        # response's `Content-Type` matches `/\bjson$/`, so anything with a
        # `; charset=utf-8` suffix (or a proxy that stripped it) leaves us
        # with the raw body as a String. Fall back to a manual JSON parse
        # so the SaaS's `data` reaches the admin either way.
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

          process.record_failure!(message, step: @step, code: error_code, data: redact_data(body_data))
        end

        # ---------------------------------------------------------------------
        # Census
        # ---------------------------------------------------------------------

        # Upstream's own gate: the publish button stays disabled until the
        # census is ready. A scheduled push checks it again, because the
        # census can change between the click and the run.
        def ensure_census_ready!
          @step = "census"
          return if election.census_ready?

          raise Decidim::Elections::Vocdoni::ApiError.new(
            "This election's census is not ready: finish it on the Census tab before voting starts",
            transient: false
          )
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

          questions_meta = election.questions.each_with_index.map do |question, index|
            upstream = remote_question_for(remote, question, index)
            next nil if upstream.blank?

            {
              "decidim_question_id" => question.id,
              "vocdoni_question_id" => (upstream["id"] || upstream["questionId"]).to_s.presence,
              "vocdoni_upstream_id" => upstream["upstreamId"].to_s.presence,
              "vocdoni_status" => upstream["status"].to_s.presence
            }
          end.compact

          size = remote_census_size(remote) || process.census_size
          process.update!(
            chain_id: remote["chainId"].to_s.presence,
            vocdoni_upstream_id: remote["upstreamId"].to_s.presence,
            census_size: size,
            metadata: process.metadata.merge("questions" => questions_meta)
          )
        end

        def remote_process
          @remote_process ||= client.elections.get(process.vocdoni_process_id).to_h
        end

        def live_upstream?(remote)
          return true if remote["published"] == true

          %w(READY ONGOING ENDED RESULTS PAUSED).include?(remote["status"].to_s)
        end

        def remote_question_for(remote, _question, index)
          questions = Array(remote["questions"])
          return nil if questions.empty?

          questions[index]
        end

        def remote_census_size(remote)
          size = remote.dig("census", "size") || remote["censusSize"]
          size&.to_i
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
          # Each question opens when the admin enables it (see UpdateQuestionOnChainJob).
          payload["initialStatus"] = "PAUSED" if election.per_question?

          payload
        end

        # Questions the admin opened or closed while the process was still
        # being pushed: their subscriber found no chain election to move.
        # The questions are read again because `election.questions` was
        # loaded when this run started, before an admin action taken during
        # the push.
        def catch_up_questions!
          return unless election.per_question?

          election.questions.reload.each do |question|
            action = if question.published_results? then "publish_results"
                     elsif question.voting_enabled_at.present? then "enable_voting"
                     end
            Decidim::Elections::Vocdoni::UpdateQuestionOnChainJob.perform_later(question.id, action) if action
          end
        end

        # An attestation binds one contact, so the code goes by email or by SMS, never both.
        def check_two_fa_fields!
          return if Process::TWO_FA_FIELDS.include?(two_fa_fields)

          raise Decidim::Elections::Vocdoni::ApiError.new(
            "The one-time code goes either by email or by SMS, not both: change it on the Security tab",
            transient: false
          )
        end

        # The census as voting starts (when this job runs) plus 20%: room for participants who join
        # it while voting is open, since the booth attests any eligible voter.
        def attested_census_size
          Process.attested_census_size(election.census.count(election))
        end

        def census_payload
          {
            "attested" => { "signer" => process.signer_address, "maxCensusSize" => attested_census_size },
            "twoFaFields" => two_fa_fields
          }
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
            "secretUntilTheEnd" => secret_until_the_end?
          }

          description = localize(question.description)
          payload["description"] = description if description.present?

          # Only multichoice carries typeSetup: singlechoice ignores it, ranked
          # and cumulative reject it. `uniqueChoices` is rejected because each
          # choice is an independent 0/1 field, so a duplicate is impossible.
          # A blank `max_choices` means no limit in Decidim, so the cap is
          # every option; the SaaS turns `maxChoices` into the ballot's
          # maxTotalCost.
          if type == "multichoice"
            max = question.max_choices.presence || question.response_options.size
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

        def two_fa_fields = process.two_fa_fields

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
