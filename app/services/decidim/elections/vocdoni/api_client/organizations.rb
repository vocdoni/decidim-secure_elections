# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      class ApiClient
        # The managed organization that owns the processes.
        #
        # A Decidim installation owns one managed Vocdoni organization
        # (`Decidim::Elections::Vocdoni.org_address`), created once with {#create_managed}.
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
        end
      end
    end
  end
end
