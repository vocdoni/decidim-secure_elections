# frozen_string_literal: true

require "rails"
require "active_support/all"
require "decidim/core"

module Decidim
  module Elections
    module Vocdoni
    # Public-facing engine: the election list and the election page, both
    # server-rendered.
    #
    # The voting page is *not* a route here. It is a static page shipped inside
    # the gem and served by middleware (see the `static_voting_page`
    # initializer), so that it needs nothing from Rails at request time. The
    # `vote` routes below survive only as redirects to it.
    class Engine < ::Rails::Engine
      isolate_namespace Decidim::Elections::Vocdoni

      # Where the static voting page is served from, relative to the application
      # root. The file itself lives at `public/vocdoni/vote.html` inside this
      # gem.
      VOTE_PATH = "/vocdoni/vote.html"

      # The address the same page used to have. Links to it were sent to real
      # voters, so `public/vocdoni/booth.html` is still shipped — as a redirect
      # that forwards the query string to `VOTE_PATH`. Nothing new points here.
      LEGACY_VOTE_PATH = "/vocdoni/booth.html"

      routes do
        resources :elections, only: [:index, :show] do
          # Kept only so that links minted before the voting page became static
          # keep working; every one of them redirects to `VOTE_PATH`.
          resource :vote, only: [:new, :show], controller: "votes" do
            get :receipt
          end

          # Cheap Decidim-local JSON used by the election page to refresh
          # status and tallies. Backed by a cached read of the SaaS API so that
          # polling never fans out into upstream calls.
          get :status, on: :member
        end

        root to: "elections#index"
      end

      initializer "decidim_elections_vocdoni.add_cells_view_paths" do
        Cell::ViewModel.view_paths << File.expand_path("#{Decidim::Elections::Vocdoni::Engine.root}/app/cells")
        Cell::ViewModel.view_paths << File.expand_path("#{Decidim::Elections::Vocdoni::Engine.root}/app/views")
      end

      initializer "decidim_elections_vocdoni.webpacker.assets_path" do
        Decidim.register_assets_path File.expand_path("app/packs", root)
      end

      # The voting page is a self-contained static page shipped inside this
      # gem: one HTML file, one JavaScript bundle, one stylesheet and one JSON
      # file per locale, all under `public/` here. Serving them from the engine
      # rather than expecting the host application to copy them into its own
      # `public/` is what makes voting work the moment the gem is installed —
      # no rake task, no `assets:precompile`, no manifest lookup.
      #
      #   GET /vocdoni/vote.html?v=<packed>
      #
      # `ActionDispatch::Static` (rather than `Rack::Static`) because it passes
      # a request for a file that does not exist straight through to the
      # application instead of answering 404, so mounting it cannot shadow a
      # route. It also handles conditional GETs, which is what keeps a page
      # updated by a gem upgrade from being served from a stale cache.
      #
      # Nothing here is served through a controller, so Decidim's
      # `Content-Security-Policy` after_action does not apply to it. That is
      # deliberate and necessary: the page talks to the Vocdoni API from the
      # browser, which Decidim's default `connect-src 'self'` would block.
      initializer "decidim_elections_vocdoni.static_voting_page" do |app|
        app.config.middleware.use(
          ::ActionDispatch::Static,
          File.expand_path("public", root),
          headers: { "cache-control" => "public, max-age=0, must-revalidate" }
        )
      end

      # Every remixicon name referenced under app/views, app/cells and
      # app/helpers. Decidim 0.33 raises on an unregistered name at render time
      # rather than falling back to a placeholder, so this list is not
      # decoration — a missing entry is a 500 on the page that uses it.
      ICONS = %w(
        add-line arrow-down-line arrow-left-line arrow-up-line
        bar-chart-box-line bill-line calendar-line calendar-schedule-line
        check-double-line check-line close-circle-line close-line
        dashboard-line delete-bin-2-line delete-bin-line draft-line
        edit-line error-warning-line external-link-line eye-line
        eye-off-line fingerprint-line group-2-line list-check loader-line
        lock-line more-fill pause-circle-line pencil-line
        play-circle-line question-answer-line question-line refresh-line
        shield-check-line stop-circle-line upload-2-line user-follow-line
      ).freeze

      # Registers an icon unless somebody already has.
      #
      # A few of these names are also registered by core modules — `bill-line`
      # by decidim-meetings, for one. Claiming them here regardless is
      # deliberate: this gem depends on decidim-core and decidim-admin only, so
      # it cannot assume the module that would otherwise register them is
      # installed, and an icon nobody registered is a crash rather than a
      # blemish.
      #
      # The guard exists because `IconRegistry#register` is not idempotent — it
      # emits a deprecation warning for every duplicate. Skipping a name that is
      # already there costs nothing, since whoever got there first registered
      # the same remixicon under the same name.
      def self.register_icon(name, icon: name, category: "system", description: "")
        return if Decidim.icons.all.has_key?(name)

        Decidim.icons.register(name:, icon:, category:, description:, engine: :vocdoni)
      end

      # Deliberately `after_initialize` rather than an `initializer`, which is
      # what every core module uses.
      #
      # Engine initializer order is not something a third-party gem gets to
      # rely on: measured in a real application, some core engines register
      # their icons before this one and some after. Whichever of us goes first
      # makes the other warn, so running last — after every engine initializer
      # has finished — is the only position from which the guard in
      # `register_icon` can actually do its job. Icons are read at render time
      # only, so there is nothing to be early for.
      config.after_initialize do
        # The resource icon, which only this module has any reason to register.
        Decidim::Elections::Vocdoni::Engine.register_icon(
          "Decidim::Elections::Vocdoni::Election",
          icon: "check-double-line", category: "activity", description: "Vocdoni election"
        )

        ICONS.each { |name| Decidim::Elections::Vocdoni::Engine.register_icon(name) }
      end
    end
  end
end
end
