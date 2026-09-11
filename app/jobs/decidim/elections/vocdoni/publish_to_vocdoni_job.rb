# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Enqueued from a subscriber to
      # `decidim.elections.admin.publish_election:after` (upstream event added
      # by vocdoni/decidim#2, integrated on `phase-4/integration`) whenever a
      # Vocdoni-backed election is published from the Decidim admin.
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
      # {Admin::AfterUpdateCensus} bootstrapped in state `pending`.
      # `Decidim::Elections::Election` and its associated tables are read-only
      # from this job's point of view.
      #
      # Only handles elections whose `census_manifest` is `"vocdoni_secure"`;
      # everything else is left alone. The subscriber that enqueues it filters
      # on the manifest, but the job double-checks so a manually enqueued run
      # cannot publish a non-Vocdoni election.
      #
      # This is a Stage-B port of the legacy `PublishElectionJob` from the
      # standalone module: same steps, same retry-safety rules, but the state
      # it reads and writes is the upstream Election plus the sidecar Process,
      # not a Vocdoni-owned Election model.
      class PublishToVocdoniJob < ApplicationJob
        # A stg-only queue so the "main" Sidekiq (which runs the legacy
        # `PublishElectionJob` on the `:vocdoni` queue for
        # decidim.vocdoni.io) never picks up a stg-spike job it does not
        # know how to load. The stg Sidekiq is the only one listening on
        # `:vocdoni_spike`, so there is no cross-contamination.
        queue_as :vocdoni_spike

        # Only transient failures (network flap, 5xx, 429) are retried — a
        # permanent rejection (4xx or a 2xx with `errors` in the body) fails
        # identically on retry and, when the failing call is `POST /members`,
        # creates fresh duplicated members upstream on each attempt.
        retry_on Decidim::Elections::Vocdoni::ApiError, wait: :polynomially_longer, attempts: 3

        MEMBER_IDENTITY_FIELDS = %w(memberNumber nationalId email phone).freeze

        # Defensive bound on the memberbase pagination walk.
        MAX_MEMBER_PAGES = 200

        # Split of the credential fields the CensusForm exposes into what the
        # Vocdoni SaaS calls authFields (proven by the census-authentication
        # step) vs twoFaFields (proven by an OTP the CSP sends to the voter).
        # Names on the right are the SaaS's own camelCase; the ones on the
        # left are how our CensusForm names them.
        AUTH_FIELD_MAP = {
          "member_number" => "memberNumber",
          "national_id"   => "nationalId",
          "date_of_birth" => "birthDate",
          "name"          => "name"
        }.freeze

        TWO_FA_FIELD_MAP = {
          "email" => "email",
          "phone" => "phone"
        }.freeze

        def perform(election_id)
          # ApplicationJob is Decidim's; it exposes `election` via
          # `attr_reader :election` in the base class, but that reader is
          # protected and shared. Rebind our local ivar here.
          @election = Decidim::Elections::Election.find_by(id: election_id)
          return if election.blank?
          return unless vocdoni_backed?

          @process = election.vocdoni_process || Process.create!(decidim_election_id: election.id, state: "pending")
          return if published_upstream?

          Decidim::Elections::Vocdoni.validate_configuration!

          process.update!(state: "publishing")

          ensure_members_pushed!
          ensure_group_created!
          ensure_group_validated!
          ensure_census_published!
          ensure_process_created!
          ensure_process_published!
          persist_process_metadata!

          process.update!(state: "published")
        rescue Decidim::Elections::Vocdoni::ApiError => e
          process.record_failure!(redact(e.message), step: @step)
          raise if e.transient?
        rescue StandardError => e
          process.record_failure!(redact(e.message), step: @step)
          raise
        end

        private

        attr_reader :process

        def vocdoni_backed?
          election.census_manifest.to_s == "vocdoni_secure"
        end

        def published_upstream?
          process.vocdoni_process_id.present? && process.published?
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

          response = client.organizations.add_members(org_address, payloads).to_h
          await_job!(response["jobId"])

          errors = Array(response["errors"]).map(&:to_s).compact_blank
          return if errors.empty?

          raise Decidim::Elections::Vocdoni::ApiError.new(
            "The Vocdoni memberbase rejected #{errors.size} of #{payloads.size} voters: #{errors.join("; ")}",
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

        def ensure_group_validated!
          @step = "validate_group"
          client.organizations.validate_group(
            org_address,
            process.census_group_id,
            auth_fields: auth_fields.presence,
            two_fa_fields: two_fa_fields.presence
          )
        rescue Decidim::Elections::Vocdoni::ApiError => e
          # A 400 here is an actionable answer, not a fault — the census is
          # unable to authenticate its own members. Bubble it up so
          # `record_failure!` catches it; it is non-transient.
          raise Decidim::Elections::Vocdoni::ApiError.new(
            e.message.to_s,
            body: e.try(:body),
            status: e.try(:status),
            code: e.try(:code),
            transient: false
          ) if e.status == 400

          raise
        end

        def ensure_census_published!
          return if process.metadata["census_id"].present?

          @step = "create_census"
          created = client.census.create(org_address).to_h
          census_id = created["id"].presence
          raise Decidim::Elections::Vocdoni::ApiError.new("POST /census returned no id", body: created, transient: false) if census_id.blank?

          @step = "publish_census"
          published = client.census.publish_group(
            census_id,
            process.census_group_id,
            auth_fields: auth_fields.presence,
            two_fa_fields: two_fa_fields.presence,
            weighted: weighted?
          ).to_h

          size = published["size"].to_i
          process.update!(
            census_size: size.positive? ? size : process.census_size,
            metadata: process.metadata.merge("census_id" => census_id)
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

        # Runs the census-manifest's `user_query` block (registered in the
        # module engine, see `phase_4_spike.rb`) and turns each row into an
        # API-shaped member payload.
        def voter_payloads
          @voter_payloads ||= census_users.map { |user| user_to_member(user) }.compact_blank
        end

        # Walks the census-manifest's `#users` iterator (which delegates to the
        # `user_query` block we registered on the manifest) to build the roster
        # for this election. `CensusManifest#users` paginates by 5 by default;
        # we ask for the full list in one shot with an oversized limit — the
        # spike's stg census is a handful of test users. When this grows into
        # real deployment the loop can be turned into a proper pager.
        def census_users
          manifest = Decidim::Elections.census_registry.find(:vocdoni_secure)
          return [] unless manifest

          Array(manifest.users(election, 0, 100_000))
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

        def resolve_member_ids!
          @step = "list_members"
          index = upstream_member_index

          census_users.map do |user|
            id = index["memberNumber:#{user.id}"] ||
                 (user.email.present? && index["email:#{user.email.strip.downcase}"])

            next nil if id.blank?

            id
          end.compact
        end

        def upstream_member_index
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

          index
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
            "groupId" => process.census_group_id,
            "weighted" => weighted?
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

          max = question.max_choices.to_i
          if type == "multichoice" || max > 1
            payload["typeSetup"] = {
              "maxChoices" => [max, 1].max,
              "minChoices" => question.mandatory? ? 1 : 0,
              "uniqueChoices" => true
            }
          end

          payload
        end

        # ---------------------------------------------------------------------
        # Config
        # ---------------------------------------------------------------------

        # The credential fields the admin ticked on the Census form, mapped
        # onto what the SaaS API expects, split across authFields (the census
        # authenticates on these) and twoFaFields (the CSP proves these via
        # an OTP delivered to the voter).
        #
        # `memberNumber` is always in authFields whether the admin picked it
        # or not, because the census still needs at least one authField and
        # every roster row we push carries a stable member number
        # (`Decidim::User#id`). This is the minimum the census needs to
        # authenticate.
        def credential_field_selection
          Array(election.census_settings["credential_fields"]).map(&:to_s)
        end

        def auth_fields
          picked = credential_field_selection
          fields = picked.filter_map { |f| AUTH_FIELD_MAP[f] }
          fields << "memberNumber" unless fields.include?("memberNumber")
          fields.uniq
        end

        def two_fa_fields
          credential_field_selection.filter_map { |f| TWO_FA_FIELD_MAP[f] }
        end

        def weighted?
          election.census_settings["weighted_votes"] == true
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
