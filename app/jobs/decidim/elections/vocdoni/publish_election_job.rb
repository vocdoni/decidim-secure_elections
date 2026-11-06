# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Enqueued from a subscriber to
      # `decidim.elections.admin.publish_election:after` (upstream event added
      # by vocdoni/decidim#2) whenever an election that has opted in to
      # Vocdoni is published from the Decidim admin.
      #
      # Talks to the Vocdoni SaaS API through the shared {ApiClient} and lands
      # the process on chain:
      #
      #   add members → create group → validate group →
      #   create census → publish census → create process → publish process →
      #   persist ids on the {Process} sidecar.
      #
      # The Vocdoni-side state (process id, chain id, group id, per-question
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

        # Only transient failures (network flap, 5xx, 429) are retried — a
        # permanent rejection (4xx or a 2xx with `errors` in the body) fails
        # identically on retry and, when the failing call is `POST /members`,
        # creates fresh duplicated members upstream on each attempt.
        retry_on Decidim::Elections::Vocdoni::ApiError, wait: :polynomially_longer, attempts: 3

        # The SaaS's largest page size for `GET /organizations/{addr}/members`.
        MEMBERS_PAGE_SIZE = 100

        # Defensive bound on the memberbase pagination walk: enough pages to
        # read a full memberbase (the SaaS caps one at 50,000 members).
        MAX_MEMBER_PAGES = 600

        # Members per `POST /organizations/{addr}/members`. The SaaS sets no
        # per-call cap, but it hashes every phone with Argon2 one after
        # another, so a batch has to finish within `Vocdoni.job_timeout`.
        # Override with `VOCDONI_MEMBER_BATCH_SIZE`.
        def self.member_batch_size
          [ENV.fetch("VOCDONI_MEMBER_BATCH_SIZE", "200").to_i, 1].max
        end

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

        def prepare_census!
          ensure_census_ready!
          ensure_members_pushed!
          ensure_group_created!
          ensure_census_validated!
        end

        # SaaS 400s carry `{"error":..., "code":..., "data":{...}}` as JSON;
        # Faraday's json middleware only parses it into a Hash when the
        # response's `Content-Type` matches `/\bjson$/`, so anything with a
        # `; charset=utf-8` suffix (or a proxy that stripped it) leaves us
        # with the raw body as a String. Fall back to a manual JSON parse
        # so `data.duplicates` / `data.missingData` reach the admin either
        # way.
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

        # Upstream's own gate: the publish button stays disabled until the
        # census is ready. A scheduled push checks it again, because the
        # census can change between the click and the run.
        def ensure_census_ready!
          @step = "census"
          return if election.census_ready?

          raise Decidim::Elections::Vocdoni::ApiError.new(
            "This election's census is not ready: finish it on the Census tab before publishing",
            transient: false
          )
        end

        def ensure_members_pushed!
          @step = "add_members"
          # Skip when we already have a group id from a previous attempt.
          return if process.census_group_id.present?

          payloads = voter_payloads
          if payloads.empty?
            raise Decidim::Elections::Vocdoni::ApiError.new(
              "This election's census resolves to zero voters — nothing to push to the Vocdoni memberbase",
              transient: false
            )
          end

          # POST /organizations/{addr}/members is *not* upsert-by-memberNumber
          # upstream: pushing the same roster twice creates fresh OrgMember docs
          # with duplicate memberNumbers, and the census publish then dupe-keys
          # on the (censusId, loginHash) unique index because the clones all
          # hash to the same auth-field value. Filter by what is already there.
          existing = upstream_member_index
          fresh = payloads.reject { |p| existing.has_key?(p["memberNumber"]) }
          return if fresh.empty?

          # A failed batch stops the push; a retry skips the batches already in.
          fresh.each_slice(self.class.member_batch_size) { |batch| push_members!(batch) }
          # The push added rows the memoized index has not seen; drop it so
          # resolve_member_ids! rewalks and picks up the new ids.
          @upstream_member_index = nil
        end

        def push_members!(batch)
          response = client.organizations.add_members(org_address, batch).to_h
          job = await_job!(response["jobId"]).to_h

          errors = (Array(response["errors"]) + Array(job["errors"])).map(&:to_s).compact_blank
          return if errors.empty?

          raise Decidim::Elections::Vocdoni::ApiError.new(
            "The Vocdoni memberbase rejected #{errors.size} of #{batch.size} voters: #{errors.join("; ")}",
            body: response,
            transient: false
          )
        end

        def ensure_group_created!
          return if process.census_group_id.present?

          @step = "create_group"
          member_ids = resolve_member_ids!
          if member_ids.empty?
            raise Decidim::Elections::Vocdoni::ApiError.new(
              "None of the census voters could be identified in the Vocdoni memberbase",
              transient: false
            )
          end

          response = client.organizations.create_group(
            org_address,
            title: group_title,
            description: group_description,
            member_ids:
          ).to_h

          group_id = response["id"].presence
          raise Decidim::Elections::Vocdoni::ApiError.new("POST /organizations/{addr}/groups returned no id", body: response, transient: false) if group_id.blank?

          process.update!(census_group_id: group_id)
        end

        # Pre-flight check that the census's authFields/twoFaFields produce
        # unique, complete credentials over the group members.
        def ensure_census_validated!
          @step = "validate_census"
          client.elections.validate_census(org_address, census_payload)
        rescue Decidim::Elections::Vocdoni::ApiError => e
          if e.status == 400
            raise Decidim::Elections::Vocdoni::ApiError.new(
              e.message.to_s,
              body: e.try(:body),
              status: e.try(:status),
              code: e.try(:code),
              transient: false
            )
          end

          raise
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
        # Voter roster
        # ---------------------------------------------------------------------

        def voter_payloads
          @voter_payloads ||= census_subjects.map do |subject|
            CensusMember.payload(election, subject, two_fa_fields:)
          end.compact_blank
        end

        # The voters of the election's upstream census, whatever its type:
        # `Decidim::User`s for `internal_users`, `Decidim::Elections::Voter`
        # rows for `token_csv`. The manifest's own query picks them, so the
        # roster follows the same rules as Decidim's census check.
        def census_subjects
          @census_subjects ||= census_records.select { |record| admitted?(record) }
        end

        # `users(election, 0, nil)` is the manifest's whole relation (a nil
        # limit is no limit); `find_each` walks it in id order, in batches.
        def census_records
          census = election.census
          return [] if census.nil?

          records = census.users(election, 0, nil)
          records = records.respond_to?(:find_each) ? records.find_each.to_a : Array(records)
          unsupported = records.reject { |record| record.is_a?(Decidim::User) || record.is_a?(Decidim::Elections::Voter) }
          return records if unsupported.empty?

          raise Decidim::Elections::Vocdoni::ApiError.new(
            "The #{election.census_manifest} census lists #{unsupported.first.class.name} records, which cannot be pushed to Vocdoni",
            transient: false
          )
        end

        # `internal_users` only queries who holds the authorizations; the
        # handlers' options (say, a postal code) are checked by the census's
        # voter form. `valid_user?` runs that same check, so a participant
        # Decidim would turn away from the booth is not pushed either.
        # CSV rows are the census as uploaded.
        def admitted?(record)
          return true unless record.is_a?(Decidim::User)

          election.census.valid_user?(election, {}, current_user: record)
        end

        # The memberbase is shared by every election of the organization, so
        # members are matched by the credential alone: an email or phone
        # match may be the same person's member from another election, whose
        # memberNumber is not this election's credential.
        def resolve_member_ids!
          @step = "list_members"
          index = upstream_member_index

          missing = 0
          ids = voter_payloads.filter_map do |payload|
            id = index[payload["memberNumber"]]
            missing += 1 if id.blank?
            id
          end
          return ids.uniq if missing.zero?

          raise Decidim::Elections::Vocdoni::ApiError.new(
            "#{missing} of #{voter_payloads.size} voters are missing from the Vocdoni memberbase after the push",
            transient: false
          )
        end

        # Memoized so ensure_members_pushed! (which reads it to dedupe against
        # the memberbase) and resolve_member_ids! (which reads it to look up
        # ids for the group) share one walk. Callers that add members must
        # invalidate `@upstream_member_index` so the next read rewalks.
        # Maps memberNumber to member id.
        def upstream_member_index
          return @upstream_member_index if @upstream_member_index

          index = {}
          page = 1
          pages = 0

          while pages < MAX_MEMBER_PAGES
            response = client.organizations.members(org_address, page:, limit: MEMBERS_PAGE_SIZE).to_h
            members = Array(response["members"]).grep(Hash)
            break if members.empty?

            members.each do |member|
              id = member["id"].presence
              number = member["memberNumber"].to_s.strip
              index[number] ||= id if id.present? && number.present?
            end

            pages += 1
            next_page = response.dig("pagination", "nextPage").to_i
            break if next_page <= page

            page = next_page
          end

          @upstream_member_index = index
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

        def census_payload
          payload = {
            "authFields" => auth_fields,
            "groupId" => process.census_group_id
          }
          payload["twoFaFields"] = two_fa_fields if two_fa_fields.any?
          payload
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
            end
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

        # Fixed to `memberNumber`: the {VoterCredential} every member we push
        # carries and the booth hands the CSP. Voters never type it, so the
        # census needs no other identifier, whatever its type.
        def auth_fields
          ["memberNumber"]
        end

        # Second-factor selection lives on the sidecar's settings, populated by
        # {Admin::UpdateElectionSecurity} from the Security-tab form. Verbatim
        # SaaS shape (`["email"]`, `["phone"]`, `["email","phone"]` or `[]`).
        def two_fa_fields
          Array(process.metadata.to_h.dig("settings", "twofa_fields")).map(&:to_s)
        end

        def org_address
          Decidim::Elections::Vocdoni.org_address
        end

        def group_title
          title = localize(election.title).to_h["default"].presence || "Decidim election"
          "#{title.truncate(180)} (##{election.id})"
        end

        def group_description
          "Census of Decidim election ##{election.id}. Managed by Decidim; do not edit by hand."
        end

        def default_locale
          @default_locale ||= (election.organization&.default_locale || Decidim.default_locale || I18n.default_locale).to_s
        end
      end
    end
  end
end
