# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    class ApiClient
      # Language maps for the SaaS API.
      #
      # The API stores every human-facing string (process title and
      # description, question title and description, choice titles) as a
      # language-keyed object and **rejects a bare string** with
      # `{"error":"invalid JSON request body","code":40004}`. The JS SDK
      # normalizes plain strings client-side; Ruby has to do exactly the same.
      #
      # The `"default"` key is the API's fallback locale and is what a voter
      # sees when their own locale is missing, so it must always be present and
      # non-blank.
      module Localizable
        # The API's fallback-locale key.
        DEFAULT_KEY = "default"

        # Key Decidim uses to nest automatic translations inside a translated
        # field. They are flattened into plain locale keys.
        MACHINE_TRANSLATIONS_KEY = "machine_translations"

        class << self
          # Normalizes a value into the API's language map.
          #
          # * `"Hi"` becomes `{"default" => "Hi"}`
          # * `{"en" => "Hi", "ca" => "Hola"}` with an `en` default locale
          #   becomes `{"default" => "Hi", "en" => "Hi", "ca" => "Hola"}`
          # * an explicit `"default"` entry always wins
          # * blank entries are dropped, and a value with nothing left to say
          #   returns `nil` so the caller can omit the field entirely
          #
          # @param value [String, Symbol, Numeric, Hash, nil] a plain string or
          #   a Decidim translated hash.
          # @param default_locale [String, Symbol, nil] locale to promote to
          #   `"default"`. Falls back to `Decidim.default_locale`, then to
          #   `I18n.default_locale`, then to the first non-blank translation.
          # @return [Hash{String => String}, nil] the language map, or nil when
          #   the value carries no text.
          def localize(value, default_locale: nil)
            translations = translations_for(value)
            return nil if translations.empty?

            fallback = default_translation(translations, default_locale)
            return nil if fallback.blank?

            { DEFAULT_KEY => fallback }.merge(translations)
          end

          private

          # @param value [Object]
          # @return [Hash{String => String}] locale => non-blank text
          def translations_for(value)
            case value
            when nil
              {}
            when Hash
              translations_from_hash(value)
            else
              text = text_for(value)
              text.present? ? { DEFAULT_KEY => text } : {}
            end
          end

          # @param hash [Hash] a Decidim translated hash, possibly carrying
          #   `machine_translations`.
          # @return [Hash{String => String}]
          def translations_from_hash(hash)
            translations = {}
            machine_translations = {}

            hash.each do |locale, value|
              key = locale.to_s

              if key == MACHINE_TRANSLATIONS_KEY
                machine_translations = value if value.is_a?(Hash)
                next
              end

              text = text_for(value)
              translations[key] = text if text.present?
            end

            merge_machine_translations(translations, machine_translations)
          end

          # Machine translations only fill the gaps: a human translation is
          # never shadowed.
          #
          # @param translations [Hash{String => String}] modified in place
          # @param machine_translations [Hash]
          # @return [Hash{String => String}]
          def merge_machine_translations(translations, machine_translations)
            machine_translations.each do |locale, value|
              key = locale.to_s
              next if translations.has_key?(key)

              text = text_for(value)
              translations[key] = text if text.present?
            end

            translations
          end

          # Nested structures are not text and are dropped rather than
          # stringified into something like `{"a" => 1}`.
          #
          # @param value [Object]
          # @return [String, nil]
          def text_for(value)
            return nil if value.nil? || value.is_a?(Hash) || value.is_a?(Array)

            value.to_s
          end

          # @param translations [Hash{String => String}]
          # @param default_locale [String, Symbol, nil]
          # @return [String, nil]
          def default_translation(translations, default_locale)
            candidates = [DEFAULT_KEY, default_locale, Decidim.default_locale, I18n.default_locale]

            candidates.each do |candidate|
              next if candidate.blank?

              text = translations[candidate.to_s]
              return text if text.present?
            end

            translations.values.find(&:present?)
          end
        end
      end
    end
  end
end
end
