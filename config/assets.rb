# frozen_string_literal: true

# Loaded outside the Rails environment, so `Rails.root` is unavailable.
base_path = File.expand_path("..", __dir__)

Decidim::Shakapacker.register_path("#{base_path}/app/packs")

Decidim::Shakapacker.register_entrypoints(
  # Admin: only the Security tab is rendered by this engine now; the pack
  # carries progressive enhancement for its form. The voter voting page is a
  # static page shipped under `public/vocdoni/`, built by `npm run build:vote`
  # and served by the engine's static middleware — nothing on the voter side
  # goes through Shakapacker or a manifest lookup at request time.
  decidim_elections_vocdoni_admin: "#{base_path}/app/packs/entrypoints/decidim_elections_vocdoni_admin.js"
)
