# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    class ApiClient
      # Organizations, their memberbase and their member groups.
      #
      # A Decidim installation owns one managed Vocdoni organization
      # (`Decidim::Elections::Vocdoni.org_address`), created once with {#create_managed}.
      # Its members are the census pool: a process census points at one of its
      # groups by id.
      #
      # Beware of the address asymmetry: these routes take and return the
      # `0x…`-prefixed form, while a process read echoes `orgAddress` back
      # unprefixed and lowercased. Normalize before comparing.
      class Organizations < Base
        # Creates a managed organization — `POST /integrator/organizations`.
        #
        # Run once, out of band; the resulting address is what
        # `VOCDONI_ORG_ADDRESS` must be set to.
        #
        # @param name [String, Hash] organization name.
        # @param type [String, Symbol] organization type (see
        #   `GET /organizations/types`).
        # @param website [String, nil]
        # @param country [String, nil]
        # @param timezone [String, nil]
        # @return [Hash] the organization, including `{"address" => "0x…"}`.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def create_managed(name:, type:, website: nil, country: nil, timezone: nil)
          body = {
            "name" => name,
            "type" => type.to_s,
            "website" => website,
            "country" => country,
            "timezone" => timezone
          }.compact

          client.post("/integrator/organizations", body:)
        end

        # Adds members to the organization memberbase —
        # `POST /organizations/{address}/members`.
        #
        # Members are matched by the census `authFields`, so whatever field the
        # census authenticates on (typically `memberNumber`) has to be present
        # and unique. Large batches are processed asynchronously by the
        # backend, in which case the answer carries a `jobId` to poll with
        # {Decidim::Elections::Vocdoni::ApiClient::Jobs#wait_for}.
        #
        # The answer never carries the ids the backend assigned — only
        # counters — so mapping a locally-held voter back onto its member id
        # goes through {#members}.
        #
        # @param org_address [String] `0x…` organization address.
        # @param members [Array<Hash>] member records — any of `id`, `email`,
        #   `phone`, `memberNumber`, `nationalId`, `name`, `surname`,
        #   `birthDate`, `weight`, `other`.
        # @param async [Boolean, nil] force the async path when true.
        # @return [Hash] `{"added" => Integer, "errors" => [...], "jobId" => …}`.
        #   `jobId` is present whenever the backend ran the import
        #   asynchronously; the caller has to poll it before assuming the
        #   memberbase is complete.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def add_members(org_address, members, async: nil)
          body = { "members" => Array(members).map { |member| member.to_h.deep_stringify_keys.compact } }
          params = async.nil? ? nil : { "async" => async }

          client.post("/organizations/#{org_address}/members", body:, params:)
        end

        # Reads the organization memberbase —
        # `GET /organizations/{address}/members`.
        #
        # Paginated. This is the only way to learn the member ids the backend
        # assigned to an import: {#add_members} answers with counters only, and
        # {#create_group} needs ids.
        #
        # @param org_address [String] `0x…` organization address.
        # @param page [Integer, nil] 1-based page number.
        # @return [Hash] `{"members" => [{"id" => …, "memberNumber" => …, …}],
        #   "pagination" => {"nextPage" => …, "lastPage" => …}}`.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def members(org_address, page: nil)
          params = page.nil? ? nil : { "page" => page }

          client.get("/organizations/#{org_address}/members", params:)
        end

        # Creates a member group — `POST /organizations/{address}/groups`.
        #
        # Step 2 of the census sequence (ARCHITECTURE §4c). Decidim creates one
        # group per election so that an admin never has to obtain, type or even
        # know a Vocdoni id: the group is internal bookkeeping.
        #
        # The title is a **plain string**, not a language map — groups are
        # organiser-side only and are never shown to a voter. The answer echoes
        # nothing but the new id (plus timestamps).
        #
        # @param org_address [String] `0x…` organization address.
        # @param title [String] group name.
        # @param description [String, nil] free-form note.
        # @param member_ids [Array<String>] internal member ids, as returned by
        #   {#members}.
        # @return [Hash] `{"id" => "…"}`.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def create_group(org_address, title:, description: nil, member_ids: [])
          body = {
            "title" => title.to_s,
            "description" => description.presence,
            "memberIds" => Array(member_ids).map(&:to_s).compact_blank
          }.compact

          client.post("/organizations/#{org_address}/groups", body:)
        end

        # Checks that every member of a group carries the fields the census
        # will authenticate on —
        # `POST /organizations/{address}/groups/{group_id}/validate`.
        #
        # Step 3 of the census sequence (ARCHITECTURE §4c), and the reason the
        # sequence is worth running: it catches "you asked to authenticate on
        # `nationalId` but twelve members have none" *before* anything is
        # written on chain.
        #
        # A 400 here is therefore an **answer, not a transport failure**, and
        # retrying it would fail identically. It arrives as
        #
        #   {"error":"invalid data provided","code":40037,
        #    "data":{"memberIds":[],"duplicates":[],
        #            "missingData":["<memberId>", …],"notFound":[]}}
        #
        # and is raised as a {Decidim::Elections::Vocdoni::ApiError} whose `body` keeps
        # `data` intact. Those member ids are the only actionable part of the
        # failure — a caller that stores just the message throws away the
        # ability to tell the admin *who* is missing *what*.
        #
        # Success is HTTP 200 with an **empty body**; no JSON comes back.
        #
        # @param org_address [String] `0x…` organization address.
        # @param group_id [String] member-group id.
        # @param auth_fields [Array<String>, nil] credentials the census
        #   authenticates on (`name`, `surname`, `memberNumber`, `nationalId`,
        #   `birthDate`).
        # @param two_fa_fields [Array<String>, nil] OTP channels (`email`,
        #   `phone`). Empty for an auth-only census.
        # @return [Hash] an empty hash on success.
        # @raise [Decidim::Elections::Vocdoni::ApiError] `status` 400 when a member lacks
        #   a requested field, is duplicated or is unknown.
        def validate_group(org_address, group_id, auth_fields: nil, two_fa_fields: nil)
          body = {
            "authFields" => field_list(auth_fields),
            "twoFaFields" => field_list(two_fa_fields)
          }.compact

          client.post("/organizations/#{org_address}/groups/#{group_id}/validate", body:)
        end

        # Lists the organization's member groups —
        # `GET /organizations/{address}/groups`.
        #
        # A process census references one of these by id. Every organization
        # has an auto-generated "All members" group (`isAutoGroup`).
        #
        # @param org_address [String] `0x…` organization address.
        # @return [Hash] `{"groups" => [{"id" => …, "title" => …,
        #   "membersCount" => …, "isAutoGroup" => …}]}`.
        # @raise [Decidim::Elections::Vocdoni::ApiError]
        def groups(org_address)
          client.get("/organizations/#{org_address}/groups")
        end

        private

        # An empty list of fields says nothing and is dropped rather than sent:
        # absent `twoFaFields` is how an auth-only census is expressed.
        #
        # @param value [Array<String, Symbol>, String, nil]
        # @return [Array<String>, nil]
        def field_list(value)
          Array(value).map(&:to_s).compact_blank.presence
        end
      end
    end
  end
end
end
