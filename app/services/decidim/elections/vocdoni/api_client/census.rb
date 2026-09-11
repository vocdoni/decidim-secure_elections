# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    class ApiClient
      # Organization-level censuses (`/census/…`).
      #
      # A process still carries its census **inline** in the create payload —
      # `census: {authFields: [...], twoFaFields: [...], groupId: "…",
      # weighted: false}` — but the group it points at has to have been
      # materialized as a CSP census first. That is what these routes do, and
      # they are steps 4 and 5 of the census sequence Decidim owns
      # (ARCHITECTURE §4c, which supersedes the "do not use `/census`" note of
      # §2.1):
      #
      #   {#create} an empty census for the organization, then
      #   {#publish_group} it from the election's member group.
      #
      # The census id is transient: the process references the *group*, so
      # nothing needs to store it afterwards.
      class Census < Base
        # Creates an empty org-level CSP census — `POST /census`.
        #
        # The auth fields may be given here or at publish time; the publish is
        # what actually binds them to the census, so passing them twice is
        # harmless and passing them only to {#publish_group} is enough.
        #
        # @param org_address [String, nil] `0x…` organization address. Defaults
        #   to the configured `Decidim::Elections::Vocdoni.org_address`.
        # @param auth_fields [Array<String>, nil] member fields the CSP
        #   authenticates on, e.g. `["memberNumber"]`.
        # @param two_fa_fields [Array<String>, nil] fields used for the OTP
        #   challenge. Leave empty for an auth-only census.
        # @return [Hash] `{"id" => "…"}`.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def create(org_address = nil, auth_fields: nil, two_fa_fields: nil)
          body = {
            "orgAddress" => org_address.presence || Decidim::Elections::Vocdoni.org_address,
            "authFields" => auth_fields,
            "twoFaFields" => two_fa_fields
          }.compact

          client.post("/census", body:)
        end

        # Reads a census — `GET /census/{id}`.
        #
        # @param census_id [String]
        # @return [Hash] `{"censusId" => …, "orgAddress" => …, "size" => …}`.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def get(census_id)
          client.get("/census/#{census_id}")
        end

        # Adds existing organization members to the census —
        # `POST /census/{id}`.
        #
        # @param census_id [String]
        # @param member_ids [Array<String>] internal member ids.
        # @return [Hash] `{"added" => Integer, "jobId" => …}`.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def add_participants(census_id, member_ids)
          client.post("/census/#{census_id}", body: { "memberIds" => Array(member_ids).map(&:to_s) })
        end

        # Lists the member ids in the census —
        # `GET /census/{id}/participants`.
        #
        # @param census_id [String]
        # @return [Hash] `{"censusId" => …, "memberIds" => [...]}`.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def participants(census_id)
          client.get("/census/#{census_id}/participants")
        end

        # Builds the Merkle census from its current participants —
        # `POST /census/{id}/publish`.
        #
        # @param census_id [String]
        # @param auth_fields [Array<String>, nil]
        # @param two_fa_fields [Array<String>, nil]
        # @param weighted [Boolean] whether members' `weight` counts as voting
        #   power.
        # @return [Hash] `{"uri" => …, "root" => …, "size" => …}`.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def publish(census_id, auth_fields: nil, two_fa_fields: nil, weighted: false)
          client.post("/census/#{census_id}/publish", body: publish_body(auth_fields, two_fa_fields, weighted))
        end

        # Publishes the census from an organization member group —
        # `POST /census/{id}/group/{group_id}/publish`.
        #
        # Step 5 of the census sequence (ARCHITECTURE §4c) and the last call
        # before `POST /processes`. Supplying only `auth_fields` yields an
        # auth-only (no OTP) CSP census; adding `two_fa_fields` is what makes
        # the voting page run `authStep1`.
        #
        # The returned `size` is the number of voters the election will report
        # as its census size.
        #
        # @param census_id [String]
        # @param group_id [String] organization member-group id.
        # @param auth_fields [Array<String>, nil]
        # @param two_fa_fields [Array<String>, nil]
        # @param weighted [Boolean] whether members' `weight` counts as voting
        #   power.
        # @return [Hash] `{"uri" => …, "root" => …, "size" => …}`.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def publish_group(census_id, group_id, auth_fields: nil, two_fa_fields: nil, weighted: false)
          client.post("/census/#{census_id}/group/#{group_id}/publish", body: publish_body(auth_fields, two_fa_fields, weighted))
        end

        private

        # `weighted` is always sent: it is a boolean the backend reads as a
        # mode, and omitting it would leave the mode to the backend's default
        # rather than to the admin's choice.
        #
        # @param auth_fields [Array<String>, nil]
        # @param two_fa_fields [Array<String>, nil]
        # @param weighted [Boolean, nil]
        # @return [Hash]
        def publish_body(auth_fields, two_fa_fields, weighted)
          {
            "authFields" => auth_fields,
            "twoFaFields" => two_fa_fields,
            "weighted" => weighted
          }.compact
        end
      end
    end
  end
end
end
