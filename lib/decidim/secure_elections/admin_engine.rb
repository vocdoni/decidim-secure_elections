# frozen_string_literal: true

module Decidim
  module SecureElections
    # Admin engine: four persistent tabs, mirroring decidim-elections.
    #
    # ```
    # Main       elections#edit    title / description / calendar / results availability
    # Questions  questions#edit    ballot editor
    # Census     census#show       voter list + auth
    # Dashboard  dashboard#show    checklist + preview / status + monitor (post-publish)
    # ```
    #
    # The tabs are always visible; a tab whose prerequisites are not yet
    # met renders as a disabled span (see the `admin_secure_elections_menu`
    # initializer below). Completeness gating for on-chain publication
    # lives on the Dashboard, not on the tabs themselves.
    #
    # Once the process is on chain the content tabs (Main / Questions /
    # Census) render read-only — an admin has to be able to see what was
    # published — while the Dashboard branches to the monitor view.
    class AdminEngine < ::Rails::Engine
      isolate_namespace Decidim::SecureElections::Admin

      paths["db/migrate"] = nil
      paths["lib/tasks"] = nil

      routes do
        resources :elections do
          member do
            put :publish
            put :unpublish
            patch :soft_delete
            patch :restore
          end
          get :manage_trash, on: :collection

          # Questions tab. Questions and their options edited together on
          # one screen — adding an option costs no page load.
          resource :questions, only: [:edit, :update], controller: "questions" do
            patch :autosave
          end

          # Census tab. `show` is the hub, `edit`/`update` is voter
          # authentication, the rest is the list of people. No route here
          # takes, or could take, a Vocdoni identifier: Decidim owns the
          # census and an administrator never sees an upstream id.
          resource :census, only: [:show, :edit, :update], controller: "census"

          get "census/members", to: "census#members", as: :census_members
          patch "census/members", to: "census#update_members", as: :census_update_members
          get "census/template", to: "census#template", as: :census_template
          post "census/import", to: "census#import", as: :census_import
          post "census/verifications", to: "census#import_from_verifications", as: :census_verifications
          delete "census/clear", to: "census#clear", as: :census_clear

          # Dashboard tab: pre-publish checklist + publish action (unpublished),
          # or live status + results + monitor controls (published/on-chain).
          resource :dashboard, only: [:show], controller: "dashboard" do
            post :publish
            delete :unpublish
            post :start
            get :refresh
            put :status
          end
        end

        root to: "elections#index"
      end

      initializer "decidim_secure_elections_admin.menu" do
        Decidim.menu :admin_secure_elections_menu do |menu|
          # Menu block runs in the controller's context, so path helpers and
          # `is_active_link?` are both in scope. Structure mirrors upstream
          # `decidim-elections`'s `admin_elections_menu`: Main links to
          # `new_election_path` on the New form so the tab is clickable and
          # detected as active, and to `edit_election_path` on every other
          # screen where the record exists. The later three tabs render as
          # a disabled span until the step they lead to is reachable.
          proxy = @election ? Decidim::EngineRouter.admin_proxy(@election.component) : nil

          menu.add_item :secure_elections_main,
                        I18n.t("main", scope: "decidim.secure_elections.admin.menu"),
                        @election.nil? ? new_election_path : proxy&.edit_election_path(@election),
                        active: @election.nil? && is_active_link?(new_election_path),
                        icon_name: "bill-line"

          menu.add_item :secure_elections_questions,
                        I18n.t("questions", scope: "decidim.secure_elections.admin.menu"),
                        @election&.step_reachable?(:questions) ? proxy&.edit_election_questions_path(@election) : "#",
                        active: @election.present? && is_active_link?(proxy&.edit_election_questions_path(@election)),
                        icon_name: "question-answer-line"

          menu.add_item :secure_elections_census,
                        I18n.t("census", scope: "decidim.secure_elections.admin.menu"),
                        @election&.step_reachable?(:census) ? proxy&.election_census_path(@election) : "#",
                        active: @election.present? && is_active_link?(proxy&.election_census_path(@election)),
                        icon_name: "group-2-line"

          menu.add_item :secure_elections_dashboard,
                        I18n.t("dashboard", scope: "decidim.secure_elections.admin.menu"),
                        @election ? proxy&.election_dashboard_path(@election) : "#",
                        active: @election.present? && is_active_link?(proxy&.election_dashboard_path(@election)),
                        icon_name: "dashboard-line"
        end
      end

      def load_seed
        nil
      end
    end
  end
end
