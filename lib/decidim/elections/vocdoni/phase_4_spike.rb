# frozen_string_literal: true

# Phase-4 spike: proves the extension surface added to upstream
# decidim-elections (vocdoni/decidim#1, #2, integrated on
# `phase-4/integration`) is enough to plug the Vocdoni backend in as an
# optional "security layer" without patching any upstream file.
#
# Under `PHASE_4_SPIKE=1` the four upstream tabs — Main, Questions,
# Census, Dashboard — are left untouched (identical to `try.decidim.org`).
# The only surface we add is a fifth admin tab, "Security", which is
# where an administrator opts in to Vocdoni-backed voting and configures
# the second-factor challenge. Opt-in is materialised by the presence of
# a `Decidim::Elections::Vocdoni::Process` sidecar row keyed to the
# election.

require "decidim/elections"
require_relative "phase_4_spike/dev_login_prefill_middleware"

module Decidim
  module Elections
    module Vocdoni
    module Phase4Spike
      class Engine < ::Rails::Engine
        engine_name "decidim_elections_vocdoni_phase_4_spike"

        paths["config/locales"] = "lib/decidim/elections/vocdoni/phase_4_spike/config/locales"

        # Pre-fill the Devise sign-in form with the default seeded admin
        # credentials in dev, matching `try.decidim.org`. This spike is only
        # ever booted in dev-mode dev_apps, but we still gate on env to be
        # explicit — never inject credentials on a non-dev boot.
        initializer "phase_4_spike.dev_login_prefill" do |app|
          if Rails.env.development?
            app.middleware.use Decidim::Elections::Vocdoni::Phase4Spike::DevLoginPrefillMiddleware
          end
        end

        # Upstream bakes the `results_availability` enum into the model from
        # `config.after_initialize` (`decidim_elections.results_availability_enum`),
        # which runs once per boot. In development the model is reloaded on
        # every code change and the enum goes with it, so the next page that
        # asks an election for its status dies with "undefined method
        # 'per_question?'" until the server is restarted — the Dashboard and
        # Publish both do. Put it back whenever it goes missing.
        #
        # The callback is registered from `after_initialize`, after upstream
        # has defined the enum, so it does nothing at boot and only ever
        # fires on a later reload — registering it as a plain `to_prepare`
        # runs it *before* upstream's own definition instead, and the two
        # collide ("already defined by another enum") before the app is up.
        #
        # Development only: nothing reloads in production, where the enum is
        # upstream's business. Belongs in the fork (vocdoni/decidim#1); it
        # lives here until it lands there.
        initializer "phase_4_spike.keep_results_availability_enum" do |app|
          next unless Rails.env.development?

          app.config.after_initialize do
            ActiveSupport::Reloader.to_prepare do
              model = Decidim::Elections::Election
              next if model.defined_enums.has_key?("results_availability")

              begin
                model.enum :results_availability, Decidim::Elections.results_availability_options.index_with(&:to_s)
              rescue ArgumentError
                # A half-reloaded class can still carry the generated
                # predicates; leaving them is better than a 500 on every page.
                nil
              end
            end
          end
        end

        # Decorate upstream `Decidim::Elections::Election` with two spike-
        # specific behaviours. Runs on every code reload in development
        # (`to_prepare`) and once in production after Zeitwerk has loaded
        # the upstream model. Idempotent.
        initializer "phase_4_spike.extend_election_model" do |app|
          app.config.to_prepare do
            # `has_one :vocdoni_process` so `election.vocdoni_process` reads
            # naturally from everywhere without the caller needing to know
            # about the sidecar table. The sidecar's presence doubles as the
            # opt-in signal now that the Security tab owns opt-in.
            Decidim::Elections::Election.has_one :vocdoni_process,
                                                 class_name: "Decidim::Elections::Vocdoni::Process",
                                                 foreign_key: "decidim_election_id",
                                                 dependent: :destroy,
                                                 inverse_of: :election

            # Publish is the point-of-no-return for a Vocdoni-backed election.
            # Upstream keeps the election editable until Start (see
            # `Election#editable?`: `published? ? !started? : !votes.exists?`)
            # — for us that is wrong: as soon as the census, the questions
            # and the endDate are anchored on chain, they cannot change.
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

            # The Census tab is rendered by this engine instead of upstream:
            # one page where the census type is chosen as a card and set up in
            # place, rather than a reloading select plus whatever form the type
            # brings. The concern carries the data that page needs and makes
            # sure our template is the one found.
            Decidim::Elections::Admin::CensusController.include(
              Decidim::Elections::Vocdoni::CensusPage
            )

            # Voter-side: whichever action of the votes controller the
            # voter lands on, hand them off to the Vocdoni booth SPA when
            # the election opted in. Otherwise the upstream per-question
            # wizard renders — for Vocdoni elections that would let a
            # voter drive Decidim's own ballot without ever touching the
            # SaaS, which is not the intent.
            Decidim::Elections::VotesController.include(
              Decidim::Elections::Vocdoni::RedirectsVoterToBooth
            )

            # Census saves re-check an opted-in election against Vocdoni and
            # clean up the rows a file census leaves behind when its type
            # changes.
            unless Decidim::Elections::Admin::ProcessCensus <= Decidim::Elections::Vocdoni::Admin::CensusSavedHook
              Decidim::Elections::Admin::ProcessCensus.prepend(
                Decidim::Elections::Vocdoni::Admin::CensusSavedHook
              )
            end
          end
        end

        # "Participants from a file": upstream's `token_csv` census, opened up
        # to any CSV. The file is uploaded and its columns mapped in our own
        # wizard (`census_file`); the voter signs in with the details the admin
        # picks on the Security tab instead of a fixed email + token pair.
        # Upstream registers the manifest in its own initializer, so it is
        # adjusted once every initializer has run. The manifest's voter pieces
        # stay generic: a Vocdoni-backed election never reaches them
        # (`RedirectsVoterToBooth`).
        initializer "phase_4_spike.census_file" do |app|
          Decidim::Elections::AdminEngine.routes.append do
            resources :elections, only: [] do
              resource :census_file, only: [:new, :create, :update, :destroy],
                                     controller: "/decidim/elections/vocdoni/admin/census_file" do
                get :template
                get :identifiers
                patch :identifiers, action: :update_identifiers
              end
            end
          end

          app.config.after_initialize do
            manifest = Decidim::Elections.census_registry.find(:token_csv)
            next if manifest.blank?

            manifest.admin_form = "Decidim::Elections::Vocdoni::AdminForms::CensusFileSettingsForm"
            # The Census tab renders its own set-up block for this census
            # (`census_setup/_file`), so the manifest no longer carries a
            # partial for upstream's page to render inside its form.
            manifest.admin_form_partial = nil
            manifest.after_update_command = nil
            manifest.user_presenter = "Decidim::Elections::Vocdoni::CensusFileVoterPresenter"
            manifest.voter_form = "Decidim::Elections::Vocdoni::VoterForms::CensusFileForm"
            manifest.voter_form_partial = "decidim/elections/vocdoni/voter_forms/census_file_form"
          end
        end

        # Injects a Security tab into upstream `Decidim::Elections::AdminEngine`.
        # The tab is where an admin opts in to Vocdoni voting for the election
        # (Enable checkbox) and picks the second-factor challenge forwarded to
        # the SaaS as `twoFaFields` at publish. Two hooks, both idempotent:
        #
        #   1. `routes.append` bolts `resource :security` onto the same nested
        #      `resources :elections` block upstream declares, so the URL sits
        #      next to the Census tab (`/elections/:id/security`). The
        #      controller is named with a leading slash to escape upstream's
        #      `isolate_namespace Decidim::Elections::Admin` — the class lives
        #      in `Decidim::Elections::Vocdoni::Admin`.
        #
        #   2. The `admin_elections_menu` block is called back every time the
        #      menu is rendered. The item is always visible so the admin can
        #      discover the Vocdoni option without extra ceremony.
        initializer "phase_4_spike.security_tab" do
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

        # Enqueues {PublishToVocdoniJob} whenever an election that has opted
        # in to Vocdoni is published from the Decidim admin. Opt-in is
        # signalled by the presence of the {Process} sidecar (created from
        # the Security tab). The subscription piggybacks on the
        # `decidim.elections.admin.publish_election:after` notification added
        # by vocdoni/decidim#2 (see phase-4/integration).
        #
        # `Decidim::Command#with_events` publishes via
        # `ActiveSupport::Notifications.publish(name, **event_arguments)`,
        # not `.instrument`. Subscribers therefore receive a 2-arg block —
        # `|event_name, data|` — where `data` is the kwargs hash, not the
        # standard 5-arg `|name, started, finished, id, payload|` shape that
        # `instrument` uses.
        initializer "phase_4_spike.subscribe_to_publish" do
          ActiveSupport::Notifications.subscribe("decidim.elections.admin.publish_election:after") do |_event_name, data|
            election = data[:election]
            next if election.blank?

            Rails.logger.info "[phase-4-spike] publish_election:after fired for election ##{election.id} (vocdoni=#{election.vocdoni_process.present?})"

            if election.vocdoni_process.present?
              Decidim::Elections::Vocdoni::PublishToVocdoniJob.perform_later(election.id)
              Rails.logger.info "[phase-4-spike] enqueued PublishToVocdoniJob for election ##{election.id}"
            end
          end
        end
      end
    end
  end
end
end
