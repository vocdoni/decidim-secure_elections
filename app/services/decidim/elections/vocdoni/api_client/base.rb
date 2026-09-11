# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    class ApiClient
      # Common ground for the sub-clients (`#elections`, `#organizations`,
      # `#census`, `#jobs`). Each one is a thin, stateless mapping of a group of
      # API routes onto snake_case Ruby methods; all the HTTP work, the error
      # mapping and the language-map normalization live in the parent client.
      class Base
        attr_reader :client

        # @param client [Decidim::Elections::Vocdoni::ApiClient] the parent client.
        def initialize(client)
          @client = client
        end

        private

        # Language map for a title/description, honouring the client's default
        # locale. See {Decidim::Elections::Vocdoni::ApiClient::Localizable.localize}.
        #
        # @param value [String, Hash, nil]
        # @return [Hash{String => String}, nil]
        def localize(value)
          client.localize(value)
        end

        # Replaces the given keys in place with their language map, dropping the
        # key entirely when there is no text (the API rejects both a bare string
        # and, for a required field, a null).
        #
        # @param attributes [Hash] hash with string keys, modified in place.
        # @param keys [Array<String>] keys to normalize.
        # @return [Hash] the same hash.
        def localize_keys!(attributes, *keys)
          keys.each do |key|
            next unless attributes.has_key?(key)

            value = localize(attributes[key])

            if value.nil?
              attributes.delete(key)
            else
              attributes[key] = value
            end
          end

          attributes
        end

        # Formats a Time/Date/DateTime the way the API expects
        # (`2026-07-29T14:51:08Z`). Strings are passed through untouched so a
        # caller can supply an already-formatted timestamp.
        #
        # @param value [Time, DateTime, Date, String, nil]
        # @return [String, nil]
        def format_timestamp(value)
          return nil if value.blank?
          return value if value.is_a?(String)
          return value.getutc.strftime(TIMESTAMP_FORMAT) if value.respond_to?(:getutc)
          return value.strftime(TIMESTAMP_FORMAT) if value.respond_to?(:strftime)

          value
        end
      end
    end
  end
end
end
