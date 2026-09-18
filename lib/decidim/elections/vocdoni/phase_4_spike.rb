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

            # Voter-side: whichever action of the votes controller the
            # voter lands on, hand them off to the Vocdoni booth SPA when
            # the election opted in. Otherwise the upstream per-question
            # wizard renders — for Vocdoni elections that would let a
            # voter drive Decidim's own ballot without ever touching the
            # SaaS, which is not the intent.
            Decidim::Elections::VotesController.include(
              Decidim::Elections::Vocdoni::RedirectsVoterToBooth
            )
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

        # Both subscribers speak the `Decidim::Command#with_events` shape:
        # `ActiveSupport::Notifications.publish(name, **event_arguments)`
        # delivers a 2-arg block — `|event_name, data|` — where `data` is
        # the kwargs hash. Not the 5-arg `|name, started, finished, id,
        # payload|` shape that `instrument` uses.

        # For manual-start elections, Publish is a no-op at the Vocdoni
        # layer — the push happens when the admin clicks Start (see the
        # `subscribe_to_start` initializer below). For scheduled elections
        # (`start_at` set to a future timestamp at publish time) the
        # subscriber schedules the push for exactly `start_at` via
        # `Sidekiq.set(wait_until:)`. Same job either way — only the
        # trigger differs. Opt-in is signalled by the presence of the
        # {Process} sidecar (created from the Security tab); on v3 the
        # subscriber also guards on the `vocdoni_secure` census manifest
        # for the manual-start log line.
        #
        # The scheduled path mirrors `decidim-blogs/PublishPostJob`, which
        # is enqueued at post-create with `wait_until: published_at`. The
        # sidekiq schedule zset holds the job in Redis until fire time and
        # then dispatches it. See `docs/spike-start-triggered-push.md` for
        # the reliability considerations.
        initializer "phase_4_spike.subscribe_to_publish" do
          ActiveSupport::Notifications.subscribe("decidim.elections.admin.publish_election:after") do |_event_name, data|
            election = data[:election]
            next if election.blank?

            Rails.logger.info "[phase-4-spike] publish_election:after fired for election ##{election.id} (vocdoni=#{election.vocdoni_process.present?})"

            next unless election.vocdoni_process.present?

            if election.start_at.present? && election.start_at.future?
              scheduled_at = election.start_at
              Decidim::Elections::Vocdoni::PushElectionJob
                .set(wait_until: scheduled_at)
                .perform_later(election.id, scheduled_at)
              Rails.logger.info "[phase-4-spike] scheduled PushElectionJob for election ##{election.id} at #{scheduled_at.iso8601}"
            else
              Rails.logger.info "[phase-4-spike] publish is a no-op for vocdoni-backed election ##{election.id}; push happens when admin clicks Start"
            end
          end
        end

        # Push happens when the election transitions into `started` —
        # either via the admin's manual Start click, or (Stage D) when a
        # scheduled `start_at` fires. Piggybacks on the notification added
        # by vocdoni/decidim#3 (`UpdateElectionStatus with_events`).
        #
        # The command handles :start, :end and :publish_results with a
        # single notification name; the subscriber filters on `action ==
        # :start` so ending an election or publishing its results does
        # not re-trigger the push.
        initializer "phase_4_spike.subscribe_to_start" do
          ActiveSupport::Notifications.subscribe("decidim.elections.admin.update_election_status:after") do |_event_name, data|
            election = data[:election]
            action   = data[:action]
            next if election.blank?
            next unless action == :start

            Rails.logger.info "[phase-4-spike] update_election_status:after fired for election ##{election.id} action=:start (vocdoni=#{election.vocdoni_process.present?})"

            if election.vocdoni_process.present?
              Decidim::Elections::Vocdoni::PushElectionJob.perform_later(election.id)
              Rails.logger.info "[phase-4-spike] enqueued PushElectionJob for election ##{election.id} (manual start)"
            end
          end
        end

        # Re-enqueue the scheduled push when the admin edits `start_at`
        # after Publish. Uses `after_update_commit` on Decidim's Election
        # model — this is a runtime class extension, not a source-file
        # patch, so no upstream file is touched.
        #
        # The old scheduled job in the sidekiq schedule zset stays queued
        # for the old timestamp; when it wakes it self-invalidates because
        # `election.start_at` no longer matches the `scheduled_start_at`
        # arg it was enqueued with (see the guard in
        # `PushElectionJob#perform`). The new job here uses the new
        # `start_at`.
        #
        # Wired via `config.after_initialize` so the callback is only
        # attached once `Decidim::Elections::Election` has been loaded by
        # its own engine — an `initializer` block runs too early for a
        # bare `Decidim::Elections::Election.class_eval` and blows up at
        # `db:create` / `db:schema:load` time with NameError.
        #
        # On z4 `cache_classes` is true so this fires once at boot and
        # the callback stays attached. In local dev the callback can
        # disappear on reload; a full server restart brings it back.
        config.after_initialize do
          Decidim::Elections::Election.class_eval do
            after_update_commit do
              next unless respond_to?(:saved_change_to_start_at?) && saved_change_to_start_at?
              next unless vocdoni_process.present?
              next unless start_at.present? && start_at.future?

              Decidim::Elections::Vocdoni::PushElectionJob
                .set(wait_until: start_at)
                .perform_later(id, start_at)
              Rails.logger.info "[phase-4-spike] rescheduled PushElectionJob for election ##{id} at #{start_at.iso8601} (start_at changed)"
            end
          end
        end
      end
    end
  end
end
end
