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

        MEMBER_IDENTITY_FIELDS = %w(memberNumber nationalId email phone).freeze

        # Defensive bound on the memberbase pagination walk.
        MAX_MEMBER_PAGES = 200

        # Cap on the demo roster — mirrors the original
        # `:vocdoni_secure` `user_query`. Keeps publish + memberbase upload
        # fast against the stg SaaS. Real deployments will replace this
        # inline query with a proper roster picked from the admin form.
        DEMO_ROSTER_LIMIT = 20

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
          fresh = payloads.reject { |p| existing.has_key?("memberNumber:#{p["memberNumber"].to_s.strip.downcase}") }
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
          roster
        end

        # Roster resolved from the election's census manifest. Returns an
        # array of `{ memberNumber, name?, email? }` hashes — the exact shape
        # `POST /organizations/{addr}/members` expects.
        #
        # The manifest determines the source: `token_csv` pushes what the
        # admin uploaded (CSV rows land in `Decidim::Elections::Voter`);
        # everything else falls back to the capped Decidim::User demo roster
        # so an admin who never picked a census still gets a workable stg
        # push.
        #
        # Local dedup by `memberNumber` mirrors the upstream-index dedup in
        # `ensure_members_pushed!`: `POST /members` is not upsert-by-
        # `memberNumber`, so two rows sharing one would either be rejected
        # or clone into duplicate `OrgMember` docs. The CSV parser dedupes
        # by email (see `CsvCensus::Data`), not by token, so a repeated
        # token in an otherwise valid CSV would fall through without this.
        def roster
          @roster ||= build_roster.uniq { |m| m["memberNumber"] }
        end

        def build_roster
          case election.census&.name.to_s
          when "token_csv"
            csv_voter_payloads
          else
            demo_user_payloads
          end
        end

        # Maps `Decidim::Elections::Voter` rows created by the token-CSV
        # upload onto the Vocdoni memberbase schema. `token` is what the
        # voter will present at the booth, so it lands as `memberNumber`
        # (the sole authField). `email` rides along to power the optional
        # email 2FA challenge; if it is missing the voter simply cannot use
        # 2FA on this row, but auth on the token still works.
        def csv_voter_payloads
          Decidim::Elections::Voter.where(election:).find_each.filter_map do |voter|
            data = voter.data.is_a?(Hash) ? voter.data : {}
            token = data["token"].to_s.strip
            next nil if token.blank?

            {
              "memberNumber" => token,
              "email" => data["email"].to_s.strip.presence
            }.compact
          end
        end

        # Demo fallback: every registered user of the org that has an email,
        # capped at `DEMO_ROSTER_LIMIT`. The cap is applied through a
        # `pluck` + `where(id:)` so it survives the outer `.limit` the
        # census-manifest paging composes on the returned relation (an outer
        # `.limit` on ActiveRecord overrides a chained inner `.limit`). The
        # `memberNumber` is the Decidim user id — stable, unique, and lets a
        # returning voter match up on the same identity across retries.
        def demo_user_payloads
          ids = Decidim::User
                .where(organization: election.organization)
                .where.not(email: nil)
                .order(id: :asc)
                .limit(DEMO_ROSTER_LIMIT)
                .pluck(:id)
          Decidim::User.where(id: ids).map do |user|
            {
              "memberNumber" => user.id.to_s,
              "name" => user.name.to_s.strip.presence,
              "email" => user.email.to_s.strip.presence
            }.compact
          end
        end

        def resolve_member_ids!
          @step = "list_members"
          index = upstream_member_index

          roster.filter_map do |member|
            number = member["memberNumber"].to_s.strip.downcase
            email = member["email"].to_s.strip.downcase

            index["memberNumber:#{number}"] || (email.present? ? index["email:#{email}"] : nil)
          end
        end

        # Memoized so ensure_members_pushed! (which reads it to dedupe against
        # the memberbase) and resolve_member_ids! (which reads it to look up
        # ids for the group) share one walk. Callers that add members must
        # invalidate `@upstream_member_index` so the next read rewalks.
        def upstream_member_index # rubocop:disable Metrics/CyclomaticComplexity
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

        # Fixed to `memberNumber` (the Decidim user id, which every roster row
        # we push carries). The Security tab does not let the admin pick auth
        # fields for the demo — `memberNumber` is a stable, unique identifier
        # over any Decidim organisation.
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
