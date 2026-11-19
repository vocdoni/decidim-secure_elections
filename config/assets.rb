# frozen_string_literal: true

# Loaded outside the Rails environment, so `Rails.root` is unavailable.
base_path = File.expand_path("..", __dir__)

Decidim::Shakapacker.register_path("#{base_path}/app/packs")

Decidim::Shakapacker.register_entrypoints(
  # Admin: the pack carries progressive enhancement for the Security tab form.
  # The voter side is the booth adapter bundle under `public/vocdoni/`, built
  # by `npm run build:booth` and served by the engine's static middleware, so
  # nothing on it goes through Shakapacker or a manifest lookup.
  decidim_elections_vocdoni_admin: "#{base_path}/app/packs/entrypoints/decidim_elections_vocdoni_admin.js"
)
