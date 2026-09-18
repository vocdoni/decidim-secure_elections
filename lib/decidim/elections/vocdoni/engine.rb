# frozen_string_literal: true

require "rails"
require "active_support/all"
require "decidim/core"
require "decidim/elections"
require_relative "dev_login_prefill_middleware"

module Decidim
  module Elections
    module Vocdoni
      # Plugs Vocdoni-backed voting into upstream `decidim-elections` as an
      # optional "security layer": the four upstream admin tabs (Main,
      # Questions, Census, Dashboard) render exactly as `try.decidim.org`;
      # this engine adds a fifth tab, "Security", between Census and
      # Dashboard, where the admin opts in and picks the second-factor
      # challenge. Opt-in is materialised by the presence of a
      # {Decidim::Elections::Vocdoni::Process} sidecar row keyed to the
      # upstream election. No upstream file is patched at runtime.
      #
      # The voter-facing "engine" surface is deliberately tiny: the voting
      # page is a static SPA under `public/vocdoni/` served by middleware
      # (see the `static_voting_page` initializer), so nothing at request
      # time depends on Rails. The engine also prepends two concerns onto
      # upstream controllers to route voters through that SPA and to move
      # the admin from Census straight to Security.
      class Engine < ::Rails::Engine
        isolate_namespace Decidim::Elections::Vocdoni

        # Where the static voting page is served from, relative to the
        # application root. The file itself lives at `public/vocdoni/vote.html`
        # inside this gem.
        VOTE_PATH = "/vocdoni/vote.html"

        # The address the same page used to have. Links to it were sent to
        # real voters, so `public/vocdoni/booth.html` is still shipped — as a
        # redirect that forwards the query string to `VOTE_PATH`. Nothing new
        # points here.
        LEGACY_VOTE_PATH = "/vocdoni/booth.html"

        initializer "decidim_elections_vocdoni.add_cells_view_paths" do
          Cell::ViewModel.view_paths << File.expand_path(
            "#{Decidim::Elections::Vocdoni::Engine.root}/app/views"
          )
        end

        initializer "decidim_elections_vocdoni.webpacker.assets_path" do
          Decidim.register_assets_path File.expand_path("app/packs", root)
        end

        # The voting page is a self-contained static page shipped inside this
        # gem: one HTML file, one JavaScript bundle, one stylesheet and one
        # JSON file per locale, all under `public/` here. Serving them from
        # the engine rather than expecting the host application to copy them
        # into its own `public/` is what makes voting work the moment the gem
        # is installed — no rake task, no `assets:precompile`, no manifest
        # lookup.
        #
        #   GET /vocdoni/vote.html?v=<packed>
        #
        # `ActionDispatch::Static` (rather than `Rack::Static`) because it
        # passes a request for a file that does not exist straight through to
        # the application instead of answering 404, so mounting it cannot
        # shadow a route. It also handles conditional GETs, which is what
        # keeps a page updated by a gem upgrade from being served from a
        # stale cache.
        #
        # Nothing here is served through a controller, so Decidim's
        # `Content-Security-Policy` after_action does not apply to it. That
        # is deliberate and necessary: the page talks to the Vocdoni API
        # from the browser, which Decidim's default `connect-src 'self'`
        # would block.
        initializer "decidim_elections_vocdoni.static_voting_page" do |app|
          app.config.middleware.use(
            ::ActionDispatch::Static,
            File.expand_path("public", root),
            headers: { "cache-control" => "public, max-age=0, must-revalidate" }
          )
        end

        # Pre-fill the Devise sign-in form with the default seeded admin
        # credentials in dev, matching `try.decidim.org`. Dev only — never
        # inject credentials on a non-dev boot.
        initializer "decidim_elections_vocdoni.dev_login_prefill" do |app|
          app.middleware.use Decidim::Elections::Vocdoni::DevLoginPrefillMiddleware if Rails.env.development?
        end

        # Decorate upstream `Decidim::Elections::Election` with the sidecar
        # association, the publish-locks-editing override, and wire up the
        # two admin/voter controller concerns. Runs on every code reload in
        # development (`to_prepare`) and once in production after Zeitwerk
        # has loaded the upstream model. Idempotent.
        initializer "decidim_elections_vocdoni.extend_upstream" do |app|
          app.config.to_prepare do
            # `has_one :vocdoni_process` so `election.vocdoni_process` reads
            # naturally from everywhere without the caller needing to know
            # about the sidecar table. The sidecar's presence doubles as the
            # opt-in signal — the Security tab owns opt-in.
            Decidim::Elections::Election.has_one :vocdoni_process,
                                                 class_name: "Decidim::Elections::Vocdoni::Process",
                                                 foreign_key: "decidim_election_id",
                                                 dependent: :destroy,
                                                 inverse_of: :election

            # Publish is the point-of-no-return for a Vocdoni-backed
            # election. Upstream keeps the election editable until Start
            # (see `Election#editable?`:
            # `published? ? !started? : !votes.exists?`) — for us that is
            # wrong: as soon as the census, the questions and the endDate
            # are anchored on chain, they cannot change.
            Decidim::Elections::Election.prepend(
              Decidim::Elections::Vocdoni::PublishLocksEditing
            )

            # Wire the Security tab into the wizard: after "Save and
            # continue" on Census, upstream would drop the admin on the
            # Dashboard. The include rewires that redirect so the admin
            # sees Security before Dashboard, matching the tab order.
            Decidim::Elections::Admin::CensusController.include(
              Decidim::Elections::Vocdoni::CensusRedirectsToSecurity
            )

            # Voter-side: whichever action of the votes controller the
            # voter lands on, hand them off to the Vocdoni booth SPA when
            # the election opted in. Otherwise the upstream per-question
            # wizard renders — for Vocdoni elections that would let a voter
            # drive Decidim's own ballot without ever touching the SaaS,
            # which is not the intent.
            Decidim::Elections::VotesController.include(
              Decidim::Elections::Vocdoni::RedirectsVoterToBooth
            )
          end
        end

        # Injects the Security tab into upstream `Decidim::Elections::AdminEngine`.
        # Two hooks, both idempotent:
        #
        #   1. `routes.append` bolts `resource :security` onto the same
        #      nested `resources :elections` block upstream declares, so the
        #      URL sits next to the Census tab (`/elections/:id/security`).
        #      The controller is named with a leading slash to escape
        #      upstream's `isolate_namespace Decidim::Elections::Admin` — the
        #      class lives in `Decidim::Elections::Vocdoni::Admin`.
        #
        #   2. The `admin_elections_menu` block is called back every time the
        #      menu is rendered. The item is always visible so the admin can
        #      discover the Vocdoni option without extra ceremony.
        initializer "decidim_elections_vocdoni.security_tab" do
          # Decidim raises unless every icon referenced by name is
          # pre-registered (`Decidim::IconRegistry#find`).
          Decidim.icons.register(name: "shield-keyhole-line",
                                 icon: "shield-keyhole-line",
                                 category: "system",
                                 description: "Security tab",
                                 engine: :core)

          Decidim::Elections::AdminEngine.routes.append do
            resources :elections, only: [] do
              resource :security, only: [:show, :update],
                                  controller: "/decidim/elections/vocdoni/admin/security"
            end
          end

          Decidim.menu :admin_elections_menu do |menu|
            election = @election
            proxy = election ? Decidim::EngineRouter.admin_proxy(election.component) : nil
            security_path = proxy&.election_security_path(election)
            # Mirror upstream's Questions/Census/Dashboard tabs: the item is
            # always rendered so an admin sees the full wizard shape from
            # the first step, but the link is a `"#"` span until the wizard
            # has reached this step — Decidim's tab CSS grays out a "#"
            # item. Security sits after Census, so it stays grayed until
            # `census_ready?` (same signal upstream uses to gate Dashboard),
            # and it grays back out once the election is no longer editable
            # so it matches Questions/Census post-publish. Position 3.5
            # slots it between Census (3) and Dashboard (4) regardless of
            # future upstream additions at either end — Decidim::Menu sorts
            # items by float position.
            enabled = election.present? && election.editable? && election.census_ready?
            menu.add_item :vocdoni_security,
                          I18n.t("security", scope: "decidim.admin.menu.elections_menu"),
                          enabled ? security_path : "#",
                          active: enabled && is_active_link?(security_path),
                          icon_name: "shield-keyhole-line",
                          position: 3.5
          end
        end

        # Publish subscriber. Three cases at publish time, one job either way
        # (`PublishElectionJob`); only the trigger differs. Opt-in is signalled
        # by the presence of the {Process} sidecar (created from the Security
        # tab).
        #
        #   1. `start_at` is in the future — schedule the push for exactly
        #      `start_at` via `Sidekiq.set(wait_until:)`. Mirrors
        #      `decidim-blogs/PublishPostJob`, which is enqueued at
        #      post-create with `wait_until: published_at`; Sidekiq holds
        #      the job in Redis until fire time and then dispatches it.
        #
        #   2. `start_at` is blank or already past — push now. Upstream
        #      considers such an election already "started" at publish time
        #      and does NOT fire `update_election_status:after` with
        #      `action == :start`, so `subscribe_to_start` below never
        #      triggers for this shape and the election would otherwise be
        #      published on Decidim but never on chain.
        #
        #   3. Admin publishes without setting a `start_at` and later clicks
        #      Start explicitly — covered by `subscribe_to_start` below.
        #
        # Both subscribers speak the `Decidim::Command#with_events` shape:
        # `ActiveSupport::Notifications.publish(name, **event_arguments)`
        # delivers a 2-arg block — `|event_name, data|` — where `data` is
        # the kwargs hash. Not the 5-arg `|name, started, finished, id,
        # payload|` shape that `instrument` uses.
        initializer "decidim_elections_vocdoni.subscribe_to_publish" do
          ActiveSupport::Notifications.subscribe("decidim.elections.admin.publish_election:after") do |_event_name, data|
            election = data[:election]
            next if election.blank?
            next if election.vocdoni_process.blank?

            if election.start_at.present? && election.start_at.future?
              scheduled_at = election.start_at
              Decidim::Elections::Vocdoni::PublishElectionJob
                .set(wait_until: scheduled_at)
                .perform_later(election.id, scheduled_at)
              Rails.logger.info "[vocdoni] scheduled PublishElectionJob for election ##{election.id} at #{scheduled_at.iso8601}"
            else
              Decidim::Elections::Vocdoni::PublishElectionJob.perform_later(election.id)
              reason = election.start_at.present? ? "start_at #{election.start_at.iso8601} already past" : "no start_at"
              Rails.logger.info "[vocdoni] enqueued PublishElectionJob for election ##{election.id} (#{reason})"
            end
          end
        end

        # Push happens when the election transitions into `started` — either
        # via the admin's manual Start click, or when a scheduled `start_at`
        # fires. Piggybacks on the notification added by vocdoni/decidim#3
        # (`UpdateElectionStatus with_events`).
        #
        # The command handles :start, :end and :publish_results with a
        # single notification name; the subscriber filters on
        # `action == :start` so ending an election or publishing its results
        # does not re-trigger the push.
        initializer "decidim_elections_vocdoni.subscribe_to_start" do
          ActiveSupport::Notifications.subscribe("decidim.elections.admin.update_election_status:after") do |_event_name, data|
            election = data[:election]
            action = data[:action]
            next if election.blank?
            next unless action == :start
            next if election.vocdoni_process.blank?

            Decidim::Elections::Vocdoni::PublishElectionJob.perform_later(election.id)
            Rails.logger.info "[vocdoni] enqueued PublishElectionJob for election ##{election.id} (manual start)"
          end
        end

        # Every remixicon name referenced under app/views, app/cells and
        # app/helpers. Decidim 0.33 raises on an unregistered name at render
        # time rather than falling back to a placeholder, so this list is
        # not decoration — a missing entry is a 500 on the page that uses
        # it.
        ICONS = %w(
          add-line arrow-down-line arrow-left-line arrow-up-line
          bar-chart-box-line bill-line calendar-line calendar-schedule-line
          check-double-line check-line close-circle-line close-line
          computer-line dashboard-line database-2-line delete-bin-2-line
          delete-bin-line draft-line edit-line error-warning-line
          external-link-line eye-line eye-off-line file-shield-2-line
          fingerprint-line government-line group-2-line information-line
          list-check loader-line lock-2-line lock-line mail-lock-line more-fill
          pause-circle-line pencil-line play-circle-line question-answer-line
          question-line refresh-line scales-3-line search-eye-line
          shield-check-line shield-keyhole-line smartphone-line
          stop-circle-line upload-2-line user-follow-line
        ).freeze

        # Registers an icon unless somebody already has.
        #
        # A few of these names are also registered by core modules —
        # `bill-line` by decidim-meetings, for one. Claiming them here
        # regardless is deliberate: this gem depends on decidim-core and
        # decidim-admin only, so it cannot assume the module that would
        # otherwise register them is installed, and an icon nobody
        # registered is a crash rather than a blemish.
        #
        # The guard exists because `IconRegistry#register` is not
        # idempotent — it emits a deprecation warning for every duplicate.
        # Skipping a name that is already there costs nothing, since
        # whoever got there first registered the same remixicon under the
        # same name.
        def self.register_icon(name, icon: name, category: "system", description: "")
          return if Decidim.icons.all.has_key?(name)

          Decidim.icons.register(name:, icon:, category:, description:, engine: :vocdoni)
        end

        # Runs after every engine initializer has finished. Two things live
        # here:
        #
        #   1. Icon registration — deliberately `after_initialize` rather
        #      than an `initializer`. Engine initializer order is not
        #      something a third-party gem gets to rely on: measured in a
        #      real application, some core engines register their icons
        #      before this one and some after. Whichever of us goes first
        #      makes the other warn, so running last — after every engine
        #      initializer has finished — is the only position from which
        #      the guard in `register_icon` can actually do its job. Icons
        #      are read at render time only, so there is nothing to be
        #      early for.
        #
        #   2. Re-enqueue the scheduled push when the admin edits `start_at`
        #      after Publish. Uses `after_update_commit` on Decidim's
        #      Election model — a runtime class extension, not a source-file
        #      patch, so no upstream file is touched. Wired in
        #      `after_initialize` so the callback is only attached once
        #      `Decidim::Elections::Election` has been loaded by its own
        #      engine — an `initializer` block runs too early for a bare
        #      `class_eval` and blows up at `db:create` /
        #      `db:schema:load` time with NameError. The old scheduled job
        #      in the sidekiq schedule zset stays queued for the old
        #      timestamp; when it wakes it self-invalidates because
        #      `election.start_at` no longer matches the
        #      `scheduled_start_at` arg it was enqueued with (see the guard
        #      in `PublishElectionJob#perform`).
        config.after_initialize do
          ICONS.each { |name| Decidim::Elections::Vocdoni::Engine.register_icon(name) }

          Decidim::Elections::Election.class_eval do
            after_update_commit do
              next unless respond_to?(:saved_change_to_start_at?) && saved_change_to_start_at?
              next if vocdoni_process.blank?
              next unless start_at.present? && start_at.future?

              Decidim::Elections::Vocdoni::PublishElectionJob
                .set(wait_until: start_at)
                .perform_later(id, start_at)
              Rails.logger.info "[vocdoni] rescheduled PublishElectionJob for election ##{id} at #{start_at.iso8601} (start_at changed)"
            end
          end
        end
      end
    end
  end
end
