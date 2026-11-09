# frozen_string_literal: true

require "faraday"

module Decidim
  module Elections
    module Vocdoni
      # Read-only client for the Vochain API (`VOCDONI_CHAIN_API_URL`). The CSP
      # checks what the chain holds (chain id, census roots, votes) here, never
      # through the SaaS, which it does not trust for that. Every failure is a
      # transient {ApiError}: the caller retries later and changes no state.
      class ChainClient
        TIMEOUT = 5
        HEX_ID = /\A(?:0x)?(\h+)\z/

        attr_reader :api_url

        def initialize(api_url: nil)
          @api_url = (api_url.presence || Vocdoni.chain_api_url).to_s.sub(%r{/+\z}, "")
        end

        def inspect = "#<#{self.class.name} api_url=#{api_url.inspect}>"
        alias to_s inspect

        # `GET /chain/info`; its `chainId` tells the production (LTS) chain apart.
        def chain_info = get("chain/info")

        # `GET /elections/{id}` for an on-chain election (32-byte hex id).
        def election(id) = get("elections/#{hex_id(id)}")

        # `GET /votes/{nullifier}`, or nil while the chain has no such vote.
        def vote(nullifier)
          get("votes/#{hex_id(nullifier)}")
        rescue ApiError => e
          return nil if e.status == 404

          raise
        end

        private

        def get(path)
          response = connection.get(path)
          return response.body if response.success?

          raise ApiError.new("Vochain API GET #{path.split("/").first} failed with HTTP #{response.status}",
                             status: response.status, body: response.body, transient: true)
        rescue Faraday::Error => e
          raise ApiError.new("Vochain API GET #{path.split("/").first} failed: #{e.class}", transient: true)
        end

        # Ids go into the path, so only hex is accepted. Error messages name
        # the route only: a vote id is a nullifier, which is never logged.
        def hex_id(value)
          match = HEX_ID.match(value.to_s)
          raise ArgumentError, "hex id expected" unless match

          match[1].downcase
        end

        def connection
          @connection ||= Faraday.new(url: "#{api_url}/") do |conn|
            conn.response :json, content_type: /\bjson\b/
            conn.headers["Accept"] = "application/json"
            conn.headers["User-Agent"] = ApiClient::USER_AGENT
            conn.options.timeout = TIMEOUT
            conn.options.open_timeout = TIMEOUT
            conn.adapter Faraday.default_adapter
          end
        end
      end
    end
  end
end
