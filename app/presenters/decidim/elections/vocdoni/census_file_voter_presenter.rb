# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Presents a row of a "Participants from a file" census in upstream's
      # census preview: a readable name rather than the first stored value.
      class CensusFileVoterPresenter < Decidim::Elections::Censuses::UserPresenter
        def identifier
          data = __getobj__.data.to_h
          full_name = [data["name"], data["surname"]].compact_blank.join(" ")
          full_name.presence || data["email"] || data["memberNumber"] || data["nationalId"] || data["phone"] || data.values.first.to_s
        end

        # A stored value for display; access codes are never shown back.
        def value(field)
          return "••••••" if field.to_s == "token" && __getobj__.data.to_h["token"].present?

          __getobj__.data.to_h[field.to_s]
        end
      end
    end
  end
end
