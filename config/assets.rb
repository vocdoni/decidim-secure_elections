# frozen_string_literal: true

# Loaded outside the Rails environment, so `Rails.root` is unavailable.
base_path = File.expand_path("..", __dir__)

Decidim::Shakapacker.register_path("#{base_path}/app/packs")

Decidim::Shakapacker.register_entrypoints(
  # Public: election list and election page (status/results polling).
  #
  # The voting page is deliberately *not* here. It is a static page shipped in
  # this gem's own `public/` directory, bundled by `npm run build:vote` and
  # served by the engine's static middleware, so it needs nothing from
  # Shakapacker, from the host application's `node_modules` or from a manifest
  # lookup at request time.
  decidim_elections_vocdoni: "#{base_path}/app/packs/entrypoints/decidim_elections_vocdoni.js",
  # Admin: the wizard and the monitoring page are server-rendered, so this pack
  # carries only progressive enhancement for forms with conditional fields.
  decidim_elections_vocdoni_admin: "#{base_path}/app/packs/entrypoints/decidim_elections_vocdoni_admin.js"
)
