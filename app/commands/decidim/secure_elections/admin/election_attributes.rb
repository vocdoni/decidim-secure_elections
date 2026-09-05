# frozen_string_literal: true

module Decidim
  module SecureElections
    module Admin
      # The election columns the **details** step writes, shared by
      # `CreateElection` and `UpdateElection`.
      #
      # Deliberately narrow. The schedule fields (`start_at`, `end_at`,
      # `manual_start`) and `results_availability` all live on the same
      # Main form now — the Calendar step is gone — but this concern still
      # owns the "which columns does the Main tab persist" contract.
      module ElectionAttributes
        extend ActiveSupport::Concern

        private

        def election_attributes
          {
            title: parsed_title,
            description: parsed_description,
            stream_uri: form.stream_uri,
            manual_start: form.manual_start,
            start_at: form.start_at,
            end_at: form.end_at,
            results_availability: form.results_availability
          }
        end

        def parsed_title
          Decidim::ContentProcessor.parse(form.title, current_organization: form.current_organization).rewrite
        end

        # Use the general `ContentProcessor.parse` (which runs every
        # registered processor Decidim has already loaded) instead of
        # asking for the `:inline_images` processor by name. The latter
        # calls `constantize` on `Decidim::ContentParsers::InlineImagesParser`,
        # which is not on the autoload path in the RSpec suite and raised
        # NameError from inside this command with no clue that the parser
        # was the missing piece. `parse` iterates over the processors the
        # engine has already registered; inline base64 images embedded in
        # a description will remain as data URIs rather than being
        # extracted to ActiveStorage blobs, which is a fair trade for the
        # description field of an election title screen.
        def parsed_description
          Decidim::ContentProcessor.parse(form.description, current_organization: form.current_organization).rewrite
        end
      end
    end
  end
end
