# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Enqueued from a subscriber to
      # `decidim.elections.admin.publish_election:after` (upstream event added
      # by vocdoni/decidim#2, integrated on `phase-4/integration`) whenever an
      # election that has opted in to Vocdoni is published from the Decidim
      # admin.
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
      class PublishToVocdoniJob < ApplicationJob
        # A stg-only queue so the "main" Sidekiq (which runs the legacy
        # `PublishElectionJob` on the `:vocdoni` queue for
        # decidim.vocdoni.io) never picks up a stg-spike job it does not
        # know how to load.
        queue_as :vocdoni_spike

        # Only transient failures (network flap, 5xx, 429) are retried — a
        # permanent rejection (4xx or a 2xx with `errors` in the body) fails
        # identically on retry and, when the failing call is `POST /members`,
        # creates fresh duplicated members upstream on each attempt.
        retry_on Decidim::Elections::Vocdoni::ApiError, wait: :polynomially_longer, attempts: 3

        MEMBER_IDENTITY_FIELDS = %w(memberNumber nationalId email phone).freeze

        # Defensive bound on the memberbase pagination walk.
        MAX_MEMBER_PAGES = 200

        # Largest roster we push. The SaaS caps the memberbase per organisation
        # (100 on staging), so a bigger census is refused with a clear message
        # instead of being silently truncated. Override with
        # `VOCDONI_MAX_ROSTER`.
        def self.max_roster
          Integer(ENV.fetch("VOCDONI_MAX_ROSTER", 100))
        end

        # Census pre-flight, run in the background by {PreflightCensusJob}:
        # pushes the roster, builds the group and asks the SaaS to validate
        # the census with the chosen identifiers and one-time code. The
        # outcome lands on `process.metadata["census_validation"]`, which the
        # Security tab shows. Never raises.
        def self.preview_census!(election_id)
          new.send(:run_preview!, election_id)
        end

        def perform(election_id)
          return unless bootstrap!(election_id)
          return if published_upstream?

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
          ensure_roster_within_limit!
          ensure_members_pushed!
          ensure_group_created!
          ensure_census_validated!
          process.record_census_validation!(ok: true, size: voter_payloads.size)
        end

        def run_preview!(election_id)
          return unless bootstrap!(election_id)
          return if published_upstream? || process.vocdoni_process_id.present?

          Decidim::Elections::Vocdoni.validate_configuration!
          prepare_census!
        rescue StandardError => e
          record_preview_failure!(e)
        end

        def record_preview_failure!(error)
          return if process.blank?

          process.record_census_validation!(
            ok: false,
            step: @step,
            code: error.respond_to?(:code) ? error.try(:code) : nil,
            message: redact(error.message),
            data: extract_error_data(error)
          )
        rescue StandardError => e
          Rails.logger.error("[vocdoni] could not record the census pre-flight failure for election ##{election&.id}: #{e.class}")
        end

        def ensure_roster_within_limit!
          @step = "roster"
          limit = self.class.max_roster
          return if census_rows.size <= limit

          raise Decidim::Elections::Vocdoni::ApiError.new(
            "The census has #{census_rows.size} people; the secure voting service accepts up to #{limit} per organisation",
            code: "roster_too_large",
            transient: false
          )
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
          body = (JSON.parse(body) rescue nil) if body.is_a?(String)
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
          fresh = payloads.reject { |p| identity_keys(p).any? { |key| existing.has_key?(key) } }
          return if fresh.empty?

          response = client.organizations.add_members(org_address, fresh).to_h
          await_job!(response["jobId"])
          # The push added rows the memoized index has not seen; drop it so
          # resolve_member_ids! rewalks and picks up the new ids.
          @upstream_member_index = nil

          errors = Array(response["errors"]).map(&:to_s).compact_blank
          return if errors.empty?

          raise Decidim::Elections::Vocdoni::ApiError.new(
            "The Vocdoni memberbase rejected #{errors.size} of #{fresh.size} voters: #{errors.join("; ")}",
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
          raise Decidim::Elections::Vocdoni::ApiError.new(
            e.message.to_s,
            body: e.try(:body),
            status: e.try(:status),
            code: e.try(:code),
            transient: false
          ) if e.status == 400

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
              "vocdoni_status"      => upstream["status"].to_s.presence
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

        def remote_question_for(remote, question, index)
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
          @voter_payloads ||= census_rows.map { |row| member_payload(row) }.compact_blank
        end

        # The people the admin put in the census, whatever its type: the
        # authorised participants of a "Registered participants" census, or
        # the rows of a "Participants from a file" one. One query, no paging
        # limit — the size is bounded by `max_roster` before anything is sent.
        def census_rows
          @census_rows ||= begin
            census = election.census
            census ? census.users(election, 0, self.class.max_roster + 1).to_a : []
          end
        end

        def member_payload(row)
          case row
          when Decidim::Elections::Voter then voter_to_member(row)
          when Decidim::User then user_to_member(row)
          end
        end

        # Maps a `Decidim::User` onto the Vocdoni memberbase schema. The
        # `memberNumber` is the Decidim user id — stable, unique, and lets a
        # returning voter match up on the same identity across retries.
        def user_to_member(user)
          {
            "memberNumber" => user.id.to_s,
            "name" => user.name.to_s.strip.presence,
            "email" => user.email.to_s.strip.presence
          }.compact
        end

        # Maps a row of a file census onto the memberbase schema. Values were
        # cleaned on import (ISO dates, digits-only phones). `weight` must be
        # sent as a string (an integer 400s with "missing members"), and the
        # Decidim-only access code never leaves this server.
        VOTER_MEMBER_FIELDS = %w(memberNumber nationalId name surname birthDate email phone weight).freeze

        def voter_to_member(voter)
          data = voter.data.to_h.stringify_keys.slice(*VOTER_MEMBER_FIELDS)
          data.transform_values { |value| value.to_s.strip }.compact_blank
        end

        def identity_keys(payload)
          MEMBER_IDENTITY_FIELDS.filter_map do |field|
            value = payload[field].to_s.strip.downcase
            "#{field}:#{value}" if value.present?
          end
        end

        def resolve_member_ids!
          @step = "list_members"
          index = upstream_member_index

          voter_payloads.filter_map do |payload|
            keys = identity_keys(payload)
            if keys.empty?
              raise Decidim::Elections::Vocdoni::ApiError.new(
                "A person in the census has no member number, ID number, email or phone, so the secure voting service cannot tell them apart",
                code: "no_identity",
                transient: false
              )
            end

            keys.lazy.filter_map { |key| index[key] }.first
          end.uniq
        end

        # Memoized so ensure_members_pushed! (which reads it to dedupe against
        # the memberbase) and resolve_member_ids! (which reads it to look up
        # ids for the group) share one walk. Callers that add members must
        # invalidate `@upstream_member_index` so the next read rewalks.
        def upstream_member_index
          return @upstream_member_index if @upstream_member_index

          index = {}
          page = 1
          pages = 0

          while pages < MAX_MEMBER_PAGES
            response = client.organizations.members(org_address, page:).to_h
            members = Array(response["members"]).grep(Hash)
            break if members.empty?

            members.each do |member|
              id = member["id"].presence
              next if id.blank?

              MEMBER_IDENTITY_FIELDS.each do |field|
                value = member[field].to_s.strip.downcase
                next if value.blank?

                index["#{field}:#{value}"] ||= id
              end
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
          "single_option"   => "singlechoice",
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

        # What voters type in the booth. A file census uses the identifiers
        # the admin chose on the Security tab (only those the SaaS accepts as
        # authFields); registered participants use their participant number
        # (`memberNumber`, the Decidim user id), which the booth launcher shows
        # to a signed-in voter.
        def auth_fields
          return ["memberNumber"] unless election.census_manifest.to_s == "token_csv"

          chosen = Array(election.census_settings.to_h["identifiers"]).map(&:to_s) & CensusCsv::Fields::AUTH
          return chosen if chosen.any?

          @step = "identifiers"
          raise Decidim::Elections::Vocdoni::ApiError.new(
            "Choose on the Security tab which details voters type to identify themselves",
            code: "no_identifiers",
            transient: false
          )
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
