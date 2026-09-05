# frozen_string_literal: true

module Decidim
  module SecureElections
    # Writes an election — and the census that decides who may vote in it — to
    # the blockchain.
    #
    #   add members -> create group -> validate group -> create census
    #   -> publish census -> create process -> publish process -> persist ids
    #
    # This is the only place in the module that creates a process, and the only
    # place that touches the organization memberbase. Decidim owns the whole
    # upstream census (ARCHITECTURE §4c): an admin enters voters in Decidim and
    # never obtains, types or even sees a Vocdoni id. The member group created
    # here is internal bookkeeping — its id is stored so a retry reuses it, and
    # it is scrubbed out of anything the admin is shown.
    #
    # The job is irreversible from the admin's point of view and is deliberately
    # resumable, so that a retry after a partial failure picks up where it
    # stopped instead of creating a second process:
    #
    #   * the whole census phase is skipped once `vocdoni_process_id` is stored
    #     — the process's census is frozen at creation, so rebuilding it later
    #     would describe a census the chain does not have;
    #   * the group is skipped once `census_group_id` is stored;
    #   * members already carrying an upstream id are not pushed again;
    #   * the process is created once, published once, and only then read back
    #     to persist the per-question Vochain election id the voter signs
    #     against.
    class PublishElectionJob < ApplicationJob
      queue_as :vocdoni

      retry_on Decidim::SecureElections::ApiError, wait: :polynomially_longer, attempts: 3

      # Member fields of the Vocdoni memberbase, mapped onto the attributes of
      # a local census-member record (ARCHITECTURE §4c). The model owns the map;
      # the job only reaches for it to read records that are not
      # {Decidim::SecureElections::CensusMember}s.
      MEMBER_FIELDS = Decidim::SecureElections::CensusMember::FIELD_ATTRIBUTES

      # Fields that can identify one member unambiguously, most specific first.
      # Used to map a local record onto the id the memberbase assigned to it.
      MEMBER_IDENTITY_FIELDS = %w(memberNumber nationalId email phone).freeze

      # `POST /organizations/{addr}/groups/{gid}/validate` reports which members
      # are unusable under `data`; every one of these lists holds member ids.
      VALIDATION_DETAIL_KEYS = %w(missingData duplicates notFound memberIds).freeze

      # Defensive bound on the memberbase pagination walk, so a backend that
      # keeps answering "there is one more page" cannot spin the worker.
      MAX_MEMBER_PAGES = 200

      def perform(election_id)
        @election = Decidim::SecureElections::Election.find_by(id: election_id)
        return if election.blank?
        return if already_live?

        Decidim::SecureElections.validate_configuration!
        return refuse_empty_census! unless census_identifies_anybody?
        return unless ensure_census_ready!

        ensure_process_created!
        ensure_process_published!
        persist_process_metadata!
      rescue StandardError => e
        record_failure!(election, e, step: @step, details: api_error_details(e))
        reset_status_after_failure!
        raise
      end

      private

      def already_live?
        return false if election.questions.exists?(vocdoni_upstream_id: nil)

        election.on_chain? && Decidim::SecureElections::Election::LIVE_STATUSES.include?(election.status)
      end

      # Where the election lands when something goes wrong.
      #
      # If no process was created it goes back to `draft` and stays editable.
      # If one *was* created the process id is kept — creating a second process
      # for the same election would be far worse than a stuck election — and
      # the status stays `publishing`, which is what the monitor page offers to
      # resume.
      def reset_status_after_failure!
        return if election.blank?
        return if election.on_chain?

        election.update_columns(status: "draft") # rubocop:disable Rails/SkipsModelValidations
      end

      # A census with neither an authentication field nor a two-factor field
      # identifies nobody (ARCHITECTURE §4c); a census with neither local voters
      # nor an existing group contains nobody. Refusing both here, before a
      # single request is made, is the last of three guards (form, model, job)
      # against publishing a census that would enfranchise every member.
      def census_identifies_anybody?
        return false unless election.census_configured?

        election.census_group_id.present? || census_member_records.any?
      end

      def refuse_empty_census!
        record_failure!(
          election,
          Decidim::SecureElections::ConfigurationError.new(
            I18n.t("decidim.secure_elections.admin.setup.errors.census_incomplete")
          ),
          step: "census"
        )
        reset_status_after_failure!
        nil
      end

      # ---------------------------------------------------------------------
      # Census (ARCHITECTURE §4c)
      #
      # members -> group -> validate -> census -> publish census
      # ---------------------------------------------------------------------

      # @return [Boolean] false when the census is unusable, in which case the
      #   job has already recorded an actionable reason and stopped.
      def ensure_census_ready!
        # A published process carries a frozen census; there is nothing left to
        # build and rebuilding it would misdescribe what is on chain.
        return true if election.vocdoni_process_id.present?

        ensure_members_pushed!
        ensure_group_created!

        if election.census_group_id.blank?
          refuse_empty_census!
          return false
        end

        return false unless ensure_group_validated!

        ensure_census_published!
        true
      end

      # Step 1 — `POST /organizations/{addr}/members`.
      #
      # Skipped when the election carries no local voter records: the census
      # then rests on a member group that already exists upstream, which is the
      # only case in which `census_group_id` is set without this job setting it.
      def ensure_members_pushed!
        @step = "add_members"
        pending = census_member_records.reject { |record| upstream_member_id(record).present? }
        return if pending.empty?

        payloads = pending.map { |record| member_payload(record) }
        response = client.organizations.add_members(org_address, payloads).to_h

        # A large import runs asynchronously: building a group out of a
        # memberbase that is still filling up would silently disenfranchise
        # whoever had not landed yet.
        await_job!(response["jobId"])

        errors = Array(response["errors"]).map(&:to_s).compact_blank
        return if errors.empty?

        raise Decidim::SecureElections::ApiError.new(
          "The Vocdoni memberbase rejected #{errors.size} of #{pending.size} voters: #{errors.join("; ")}",
          body: response
        )
      end

      # Step 2 — `POST /organizations/{addr}/groups`.
      #
      # The group is created per election and titled after it, so the upstream
      # memberbase stays readable to whoever operates the Vocdoni organization.
      # Its id is never shown in Decidim.
      #
      # It is rebuilt on every attempt for which Decidim owns the voter list,
      # because it is the *group* — not the local list — that the census is
      # published from: reusing one built before the admin fixed the census
      # would silently disenfranchise whoever was added since. Groups are
      # invisible to admins and cost nothing, so a superseded one is left
      # behind rather than deleted.
      #
      # An election that carries a group id but no local voters keeps it: that
      # is a census that only exists upstream.
      def ensure_group_created!
        member_ids = resolve_member_ids!
        return if member_ids.empty?

        @step = "create_group"
        response = client.organizations.create_group(
          org_address,
          title: group_title,
          description: group_description,
          member_ids:
        ).to_h

        group_id = response["id"].presence
        raise Decidim::SecureElections::ApiError.new("POST /organizations/{address}/groups returned no id", body: response) if group_id.blank?

        election.update!(census_group_id: group_id)
      end

      # Step 3 — `POST /organizations/{addr}/groups/{gid}/validate`.
      #
      # The call that catches a census unable to authenticate its own members
      # before anything reaches the chain. Its 400 is an answer rather than a
      # fault: retrying it would fail identically, so the job records *which*
      # members lack *which* field and stops, leaving the election editable.
      #
      # @return [Boolean] false when the group is not usable.
      def ensure_group_validated!
        @step = "validate_group"
        client.organizations.validate_group(
          org_address,
          election.census_group_id,
          auth_fields: election.auth_fields.presence,
          two_fa_fields: election.two_fa_fields.presence
        )
        true
      rescue Decidim::SecureElections::ApiError => e
        raise unless e.status == 400

        record_failure!(election, e, step: @step, details: api_error_details(e))
        reset_status_after_failure!
        false
      end

      # Steps 4 and 5 — `POST /census`, then
      # `POST /census/{id}/group/{gid}/publish`.
      #
      # The census object is transient: the process references the *group*, so
      # there is nothing to store afterwards and the schema has no column for
      # it (ARCHITECTURE §4b). What the publish yields that matters is the size —
      # the number of voters the chain will accept.
      def ensure_census_published!
        @step = "create_census"
        created = client.census.create(org_address).to_h
        @census_id = created["id"].presence
        raise Decidim::SecureElections::ApiError.new("POST /census returned no id", body: created) if @census_id.blank?

        @step = "publish_census"
        published = client.census.publish_group(
          @census_id,
          election.census_group_id,
          auth_fields: election.auth_fields.presence,
          two_fa_fields: election.two_fa_fields.presence,
          weighted: weighted?
        ).to_h

        size = published["size"].to_i
        election.update!(census_size: size) if size.positive?
      end

      # ---------------------------------------------------------------------
      # Members
      # ---------------------------------------------------------------------

      # The local voter records to push upstream
      # ({Decidim::SecureElections::CensusMember}).
      #
      # Guarded on the association rather than assuming it: an election whose
      # census exists only upstream (a group id and no local rows) is still a
      # valid, if legacy, configuration and must not be rebuilt.
      def census_member_records
        @census_member_records ||=
          if election.class.reflect_on_association(:census_members)
            election.census_members.to_a
          else
            []
          end
      end

      # `POST …/members` answers with counters only, never with the ids it
      # assigned, so they have to be read back and matched. Matching is by
      # credential — member number, national id, email, phone — which is
      # precisely what the census will authenticate on, so a record that cannot
      # be matched here could not have been identified when voting either.
      #
      # @return [Array<String>] upstream member ids, in local order.
      def resolve_member_ids!
        records = census_member_records
        return [] if records.empty?

        index = records.all? { |record| upstream_member_id(record).present? } ? {} : upstream_member_index

        records.map do |record|
          id = upstream_member_id(record).presence || lookup_member_id(index, record)

          if id.blank?
            raise Decidim::SecureElections::ApiError, "A voter of this census carries no member number, national id, email or phone, so the Vocdoni memberbase cannot identify them"
          end

          remember_member_id!(record, id)
          id
        end
      end

      # Walks `GET /organizations/{addr}/members` and indexes every member id
      # under each of its credentials.
      #
      # @return [Hash{String => String}] `"field:value"` => member id
      def upstream_member_index
        @step = "list_members"
        index = {}
        page = 1
        pages = 0

        while pages < MAX_MEMBER_PAGES
          response = client.organizations.members(org_address, page:).to_h
          members = Array(response["members"]).grep(Hash)
          break if members.empty?

          index_members!(index, members)
          pages += 1

          next_page = response.dig("pagination", "nextPage").to_i
          break if next_page <= page

          page = next_page
        end

        index
      end

      # @param index [Hash] modified in place
      # @param members [Array<Hash>] upstream members
      def index_members!(index, members)
        members.each do |member|
          id = member["id"].presence
          next if id.blank?

          MEMBER_IDENTITY_FIELDS.each do |field|
            key = index_key(field, member[field])
            next if key.blank?

            # First wins: a duplicated credential is the backend's problem and
            # is reported by the group validation, not silently re-pointed here.
            index[key] ||= id
          end
        end
      end

      # @param index [Hash{String => String}]
      # @param record [Object] a local census member
      # @return [String, nil]
      def lookup_member_id(index, record)
        MEMBER_IDENTITY_FIELDS.each do |field|
          key = index_key(field, member_value(record, field))
          next if key.blank?

          id = index[key]
          return id if id.present?
        end

        nil
      end

      # @param field [String] API field name
      # @param value [Object]
      # @return [String, nil]
      def index_key(field, value)
        normalized = value.to_s.strip.downcase
        return nil if normalized.blank?

        "#{field}:#{normalized}"
      end

      # @param record [Object] a local census member
      # @return [Hash] the member as the API expects it
      def member_payload(record)
        # `CensusMember` owns the mapping onto the memberbase schema; the
        # fallback only serves records that do not come from that model.
        return record.to_api_member.to_h if record.respond_to?(:to_api_member)

        MEMBER_FIELDS.keys.index_with { |field| member_value(record, field) }.compact_blank
      end

      # @param record [Object] a local census member
      # @param field [String] API field name
      # @return [String, Integer, nil]
      def member_value(record, field)
        value = record.respond_to?(:value_for) ? record.value_for(field) : record.try(MEMBER_FIELDS.fetch(field))
        return nil if value.blank?

        case field
        when "birthDate"
          # ASSUMPTION: the memberbase stores birth dates as ISO-8601 dates.
          value.respond_to?(:strftime) ? value.strftime("%Y-%m-%d") : value.to_s.strip
        when "weight"
          # A string, not a number. The API rejects an integer weight with
          # `400 {"error":"invalid JSON request body: missing members"}` — a
          # message that names the wrong field entirely, which is why this is
          # worth a comment (ARCHITECTURE §4c). `to_i` first so that a weight
          # arriving as "3.7" is sent as the whole number it has to be.
          value.to_i.to_s
        else
          value.to_s.strip
        end
      end

      # @param record [Object] a local census member
      # @return [String, nil]
      def upstream_member_id(record)
        record.try(:vocdoni_member_id).presence
      end

      # Kept on the local record so a later run does not have to walk the
      # memberbase again. Silently skipped while the census-member model has no
      # such column.
      def remember_member_id!(record, id)
        return unless record.respond_to?(:has_attribute?) && record.has_attribute?(:vocdoni_member_id)
        return if record.vocdoni_member_id == id

        record.update_columns(vocdoni_member_id: id) # rubocop:disable Rails/SkipsModelValidations
      end

      # ---------------------------------------------------------------------
      # Process
      # ---------------------------------------------------------------------

      def ensure_process_created!
        return if election.vocdoni_process_id.present?

        @step = "create_process"
        response = client.elections.create(process_payload).to_h
        process_id = response["processId"].presence

        raise Decidim::SecureElections::ApiError.new("POST /processes returned no processId", body: response) if process_id.blank?

        # Persisted immediately: from this instant the election is on chain and
        # must never be edited or recreated.
        election.update!(vocdoni_process_id: process_id, status: "publishing")
      end

      def ensure_process_published!
        return if live_upstream?(remote_process)

        @step = "publish_process"
        response = client.elections.publish(election.vocdoni_process_id).to_h
        await_job!(response["jobId"])

        @remote_process = nil
      end

      def persist_process_metadata!
        @step = "persist"
        process = remote_process

        election.questions.each_with_index do |question, index|
          upstream = remote_question_for(process, question, index)
          next if upstream.blank?

          question.update_columns( # rubocop:disable Rails/SkipsModelValidations
            # `GET /processes/{id}` names the question's own id `id`; the
            # results endpoint calls the same value `questionId`.
            vocdoni_question_id: (upstream["id"] || upstream["questionId"]).presence,
            # The Vochain election id — what the voter signs and votes against.
            vocdoni_upstream_id: upstream["upstreamId"].presence,
            vocdoni_status: Decidim::SecureElections::Question.normalize_status(upstream["status"]) || "ready"
          )
        end

        election.update!(
          vocdoni_chain_id: process["chainId"].presence,
          census_size: remote_census_size(process) || election.census_size,
          status: Decidim::SecureElections::Election.normalize_status(process["status"]) || "ready",
          results_cache: election.results_cache.to_h.except("error")
        )

        Decidim::SecureElections::SyncResultsJob.perform_later(election.id)
      end

      # ---------------------------------------------------------------------
      # Remote reads
      # ---------------------------------------------------------------------

      # `GET /processes/{id}` is public and cheap; reading it before publishing
      # is what makes a retry safe.
      def remote_process
        @remote_process ||= client.elections.get(election.vocdoni_process_id).to_h
      end

      # A process that has already been published reports a live status (and,
      # in the API's own vocabulary, `ONGOING`). Checking this before calling
      # publish is what makes a retry safe.
      def live_upstream?(process)
        return true if process["published"] == true

        Decidim::SecureElections::Election::LIVE_STATUSES.include?(
          Decidim::SecureElections::Election.normalize_status(process["status"])
        )
      end

      # ASSUMPTION: `GET /processes/{id}` returns the questions in the same
      # order they were submitted. Matching is done by id when the payload
      # carries one we already know, and falls back to position otherwise.
      def remote_question_for(process, question, index)
        questions = Array(process["questions"])
        return nil if questions.empty?

        by_id = questions.find do |upstream|
          question.vocdoni_question_id.present? &&
            [upstream["id"], upstream["questionId"]].compact.map(&:to_s).include?(question.vocdoni_question_id)
        end

        by_id || questions[index]
      end

      def remote_census_size(process)
        size = process.dig("census", "size") || process["censusSize"]
        size&.to_i
      end

      # ---------------------------------------------------------------------
      # Payload (ARCHITECTURE §2.1 and §2.3)
      #
      # Language maps and timestamp formatting are the client's job; what is
      # built here is the shape.
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

        # Omitted when the admin chose a manual start; in that case the process
        # begins PAUSED and the admin explicitly starts it from the Dashboard.
        payload["startDate"] = election.start_at if election.start_at.present? && !election.manual_start?

        # A manual-start election is created paused so that it only becomes
        # active when the admin presses "Start election" on the Dashboard.
        # `interruptible` lets the process be paused again after it starts.
        if election.manual_start?
          payload["paused"] = true
          payload["interruptible"] = true
        end

        payload
      end

      # The census is inline in the process payload and points at the group
      # built above. `twoFaFields` comes back on the *public* process read,
      # which is how the voting page knows whether to run `authStep1`.
      def census_payload
        census = {
          "authFields" => election.auth_fields,
          "groupId" => election.census_group_id,
          "weighted" => weighted?
        }
        # Omitted when empty so the process stays auth-only and the page skips
        # `authStep1`.
        census["twoFaFields"] = election.two_fa_fields if election.two_fa_fields.any?
        census
      end

      def question_payload(question)
        payload = {
          "title" => localize(question.title),
          # Lowercase: camelCase is rejected with code 40037.
          "type" => question.question_type,
          "choices" => question.answers.map do |answer|
            { "title" => localize(answer.title), "value" => answer.value }
          end
        }

        description = localize(question.description)
        payload["description"] = description if description.present?
        payload["secretUntilTheEnd"] = true if question.secret_until_the_end?

        if question.multichoice?
          payload["typeSetup"] = {
            "maxChoices" => question.effective_max_choices,
            "minChoices" => question.effective_min_choices,
            "uniqueChoices" => true
          }
        end

        payload
      end

      # ---------------------------------------------------------------------
      # Helpers
      # ---------------------------------------------------------------------

      def org_address
        Decidim::SecureElections.org_address
      end

      # Voting power. When false the members' `weight` is ignored upstream and
      # every voter counts as one.
      def weighted?
        election.weighted? == true
      end

      # Titled after the election so that the memberbase stays legible upstream.
      # Never rendered in Decidim — the group is an implementation detail of the
      # census: Decidim owns the census and never shows a Vocdoni id.
      def group_title
        title = localize(election.title).to_h["default"].presence || "Decidim election"

        "#{title.truncate(180)} (#{election_slug})"
      end

      def group_description
        "Census of the Decidim election #{election_slug}. Managed by Decidim; do not edit by hand."
      end

      def election_slug
        election.reference.presence || "election ##{election.id}"
      end

      # The actionable part of an upstream refusal. A census validation reports
      # `data: {missingData: [...], duplicates: [...], notFound: [...]}`, each a
      # list of *member ids*, which the admin surface maps back onto local
      # records so the admin reads "Carol and Dave have no national id" instead
      # of "code 40037".
      #
      # @param error [StandardError]
      # @return [Hash{String => Array<String>}, nil]
      def api_error_details(error)
        body = error.try(:body)
        return nil unless body.is_a?(Hash)

        data = body["data"]
        data = body unless data.is_a?(Hash)

        details = data.slice(*VALIDATION_DETAIL_KEYS)
                      .transform_values { |value| Array(value).map(&:to_s).compact_blank }
                      .reject { |_key, value| value.empty? }

        details.presence
      end

      # Vocdoni ids of the census plumbing are internal to this module and would
      # otherwise leak into the admin UI through the request URL an error
      # message quotes.
      def redact(message)
        text = super
        [election&.census_group_id, @census_id].each do |internal_id|
          text = text.gsub(internal_id, "[census]") if internal_id.present?
        end
        text
      end
    end
  end
end
