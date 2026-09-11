# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    class ApiClient
      # Processes — what Decidim calls elections.
      #
      # A process holds many questions, and **each question is a separate
      # Vochain election** (`questions[i].upstreamId`). The process id handled
      # here is always the SaaS Mongo ObjectID (24 hex chars), never an
      # `upstreamId` and never a `0x…` on-chain id.
      #
      # Two normalizations happen on the way out, both of them mandatory:
      #
      # * every human-facing string becomes a language map — the API answers
      #   `{"error":"invalid JSON request body","code":40004}` to a bare string;
      # * question types are downcased — `"singleChoice"` is rejected with code
      #   40037.
      class Elections < Base
        # Fields of a process draft that carry text.
        LOCALIZED_PROCESS_KEYS = %w(title description).freeze

        # Fields of a question that carry text.
        LOCALIZED_QUESTION_KEYS = %w(title description).freeze

        # Timestamp fields of a process draft.
        TIMESTAMP_KEYS = %w(startDate endDate).freeze

        # Creates a process draft — `POST /processes`.
        #
        # The draft is stored in the SaaS backend only; nothing reaches the
        # chain until {#publish}. `orgAddress` defaults to the configured
        # `Decidim::Elections::Vocdoni.org_address`, `startDate` may be omitted (the
        # process then starts as soon as it is published) and the census is
        # inline: `{authFields: [...], groupId: "…", weighted: false}`.
        #
        # @param payload [Hash] the process draft. Titles, descriptions and
        #   choice titles may be plain strings or Decidim translated hashes.
        # @return [Hash] `{"processId" => "…"}`.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        #
        # @example
        #   client.elections.create(
        #     title: { "en" => "Board election" },
        #     endDate: 2.days.from_now,
        #     census: { authFields: ["memberNumber"], groupId: group_id, weighted: false },
        #     questions: [{ title: "Chair?", type: "singlechoice",
        #                   choices: [{ title: "Yes", value: 0 }, { title: "No", value: 1 }] }]
        #   )
        def create(payload)
          client.post("/processes", body: normalize_process(payload))
        end

        # Reads a process — `GET /processes/{id}`.
        #
        # This is the only supported source of `chainId` (never `GET /info`).
        # The route is public for published processes; drafts are only visible
        # to an org manager/admin or a scoped API key, so the API key is sent
        # whenever there is one.
        #
        # @param process_id [String] SaaS process id (Mongo ObjectID).
        # @param authenticated [Boolean] set to false to force an anonymous
        #   read, which never touches the API key.
        # @return [Hash] the process, including `chainId`, `census` and
        #   `questions` (each with its `upstreamId` and `status`).
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def get(process_id, authenticated: true)
          client.get("/processes/#{process_id}", auth: read_auth(authenticated))
        end

        # Publish-readiness dry-run — `GET /processes/{id}/validation`.
        #
        # Does not touch the process. Not to be confused with
        # `POST /processes/{id}/check`, the public voter-eligibility route.
        #
        # @param process_id [String] SaaS process id.
        # @return [Hash] `{"valid" => true|false, "errors" => [...]}`.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def validate(process_id)
          client.get("/processes/#{process_id}/validation")
        end

        # Publishes a draft on chain — `POST /processes/{id}/publish`.
        #
        # Asynchronous: the answer is `{"jobId" => "…"}`, to be polled with
        # {Decidim::Elections::Vocdoni::ApiClient::Jobs#wait_for}. An already-published
        # process answers `{"address" => "…", "status" => "…"}` instead.
        #
        # This request is never retried — a duplicate publish would submit a
        # second on-chain transaction.
        #
        # @param process_id [String] SaaS process id.
        # @return [Hash] `{"jobId" => "…"}` or `{"address" => …, "status" => …}`.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def publish(process_id)
          client.post("/processes/#{process_id}/publish")
        end

        # Reads the tallies — `GET /processes/{id}/results`.
        #
        # Public route. The per-question `results` matrix is absent until a
        # tally exists (no vote yet, or a `secretUntilTheEnd` question still
        # encrypted), so treat absence as "not available yet".
        #
        # @param process_id [String] SaaS process id.
        # @param authenticated [Boolean] set to false to force an anonymous
        #   read, which never touches the API key.
        # @return [Hash] `{"id" => …, "questions" => [{"questionId" => …,
        #   "voteCount" => …, "results" => [[…]]}]}`.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def results(process_id, authenticated: true)
          client.get("/processes/#{process_id}/results", auth: read_auth(authenticated))
        end

        # Moves several questions to a new status —
        # `PUT /processes/{id}/questions/status`.
        #
        # Asynchronous: answers `{"jobId" => "…"}`. Since each question is its
        # own Vochain election there is no process-level status route; pausing
        # or ending "the election" means moving all of its questions.
        #
        # @param process_id [String] SaaS process id.
        # @param status [String, Symbol] target status, spelled the way the API
        #   expects it (`READY`, `PAUSED`, `ENDED`, `CANCELED`, `RESULTS`). It
        #   is sent verbatim.
        # @param question_ids [Array<String>, nil] questions to move. Omit (or
        #   pass nil/empty) to target every published question of the process.
        # @return [Hash] `{"jobId" => "…"}`.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def bulk_set_question_status(process_id, status:, question_ids: nil)
          body = { "status" => status.to_s }
          ids = Array(question_ids).map(&:to_s).compact_blank
          body["questions"] = ids.map { |id| { "id" => id } } if ids.any?

          client.put("/processes/#{process_id}/questions/status", body:)
        end

        # Looks up census participants —
        # `GET /processes/{id}/participants?field=&value=`.
        #
        # Manager/admin only. Returns the org members matching the lookup that
        # belong to the process census, each with its per-question voted
        # status. An empty list means "no match", not an error.
        #
        # @param process_id [String] SaaS process id.
        # @param field [String, Symbol] one of `email`, `phone`,
        #   `memberNumber`, `nationalId`. Name/surname/birthDate are not
        #   queryable.
        # @param value [String] the value to match.
        # @return [Hash] `{"participants" => [{"memberId" => …, "questions" => [...]}]}`.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def participants(process_id, field:, value:)
          client.get("/processes/#{process_id}/participants", params: { "field" => field.to_s, "value" => value.to_s })
        end

        private

        # @param authenticated [Boolean]
        # @return [Symbol] an auth mode for {Decidim::Elections::Vocdoni::ApiClient#request}
        def read_auth(authenticated)
          authenticated ? :optional : :none
        end

        # @param payload [Hash] a process draft with string or symbol keys
        # @return [Hash] the API-ready body
        def normalize_process(payload)
          attributes = payload.to_h.deep_stringify_keys

          org_address = attributes["orgAddress"].presence || Decidim::Elections::Vocdoni.org_address
          attributes["orgAddress"] = org_address if org_address.present?

          localize_keys!(attributes, *LOCALIZED_PROCESS_KEYS)
          normalize_timestamps!(attributes)

          questions = attributes["questions"]
          attributes["questions"] = questions.map { |question| normalize_question(question) } if questions.is_a?(Array)

          attributes
        end

        # @param attributes [Hash] modified in place
        # @return [Hash]
        def normalize_timestamps!(attributes)
          TIMESTAMP_KEYS.each do |key|
            next unless attributes.has_key?(key)

            timestamp = format_timestamp(attributes[key])

            if timestamp.blank?
              attributes.delete(key)
            else
              attributes[key] = timestamp
            end
          end

          attributes
        end

        # @param question [Hash]
        # @return [Hash]
        def normalize_question(question)
          attributes = question.to_h.deep_stringify_keys

          localize_keys!(attributes, *LOCALIZED_QUESTION_KEYS)

          # `singleChoice` is rejected with code 40037.
          attributes["type"] = attributes["type"].to_s.downcase if attributes["type"].present?

          choices = attributes["choices"]
          attributes["choices"] = choices.map { |choice| normalize_choice(choice) } if choices.is_a?(Array)

          attributes
        end

        # @param choice [Hash]
        # @return [Hash]
        def normalize_choice(choice)
          localize_keys!(choice.to_h.deep_stringify_keys, "title")
        end
      end
    end
  end
end
end
