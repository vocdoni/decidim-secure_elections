# frozen_string_literal: true

module Decidim
  module SecureElections
    module Admin
      # The election list, the trash, and the **Main** tab: everything an
      # admin decides about the election itself.
      #
      # `new`/`create` and `edit`/`update` render and save the same form —
      # a title, a description, an optional video, the schedule, and how
      # results are shown — collapsed into three accordion cards on one
      # page. The Calendar step of the old wizard is gone; its attributes
      # live on this form now.
      #
      # `QuestionsController`, `CensusController` and the dashboard each
      # sit under their own tab in the four-tab strip. The tabs are not a
      # wizard: an admin can move between them freely, and the
      # completeness checks live on the dashboard rather than gating the
      # tabs themselves.
      class ElectionsController < Admin::ApplicationController
        include Decidim::Admin::HasTrashableResources
        include Decidim::Admin::Filterable

        helper_method :elections, :election

        def index
          enforce_permission_to :read, :election
        end

        # `resources :elections` exposes a canonical show route. The admin
        # panel has no separate "election page" — the Dashboard tab is where
        # an admin lands to see the state of a single election.
        def show
          enforce_permission_to :read, :election

          redirect_to election_dashboard_path(election)
        end

        def new
          enforce_permission_to :create, :election

          @form = form(Decidim::SecureElections::Admin::ElectionForm).instance
        end

        def create
          enforce_permission_to :create, :election

          @form = form(Decidim::SecureElections::Admin::ElectionForm).from_params(params, current_component:)

          Decidim::SecureElections::Admin::CreateElection.call(@form) do
            on(:ok) do |election|
              flash[:notice] = I18n.t("elections.create.success", scope: "decidim.secure_elections.admin")
              # Straight on to the ballot editor, where the admin adds
              # questions before publishing the election.
              redirect_to edit_election_questions_path(election)
            end

            on(:invalid) do
              flash.now[:alert] = I18n.t("elections.create.invalid", scope: "decidim.secure_elections.admin")
              render action: "new", status: :unprocessable_content
            end
          end
        end

        def edit
          enforce_permission_to :read, :election

          @form = form(Decidim::SecureElections::Admin::ElectionForm).from_model(election, election:)
        end

        def update
          enforce_permission_to(:update, :election, election:)

          @form = form(Decidim::SecureElections::Admin::ElectionForm).from_params(params, current_component:, election:)

          Decidim::SecureElections::Admin::UpdateElection.call(@form, election) do
            on(:ok) do
              flash[:notice] = I18n.t("elections.update.success", scope: "decidim.secure_elections.admin")
              redirect_to edit_election_path(election)
            end

            on(:invalid) do
              flash.now[:alert] = I18n.t("elections.update.invalid", scope: "decidim.secure_elections.admin")
              render action: "edit", status: :unprocessable_content
            end
          end
        end

        # Decidim visibility only — this makes the election's page reachable on
        # the public site. It writes nothing to the blockchain; that is the
        # setup step, and the two must never be mistaken for each other.
        def publish
          enforce_permission_to(:publish, :election, election:)

          Decidim::SecureElections::Admin::PublishElection.call(election, current_user) do
            on(:ok) do
              # A page nobody can vote on is the half of this that an admin gets
              # wrong, so an election that has not reached the chain says so
              # rather than leaving "it is live" to be assumed.
              # i18n-tasks-use t("decidim.secure_elections.admin.elections.publish.success")
              # i18n-tasks-use t("decidim.secure_elections.admin.elections.publish.success_not_on_chain")
              key = election.on_chain? ? "success" : "success_not_on_chain"
              flash[:notice] = I18n.t("elections.publish.#{key}", scope: "decidim.secure_elections.admin")
              redirect_to elections_path
            end

            on(:invalid) do
              flash[:alert] = I18n.t("elections.publish.invalid", scope: "decidim.secure_elections.admin")
              redirect_to elections_path
            end
          end
        end

        def unpublish
          enforce_permission_to(:unpublish, :election, election:)

          Decidim::SecureElections::Admin::UnpublishElection.call(election, current_user) do
            on(:ok) do
              flash[:notice] = I18n.t("elections.unpublish.success", scope: "decidim.secure_elections.admin")
              redirect_to elections_path
            end

            on(:invalid) do
              flash[:alert] = I18n.t("elections.unpublish.invalid", scope: "decidim.secure_elections.admin")
              redirect_to elections_path
            end
          end
        end

        private

        def elections
          @elections ||= filtered_collection
        end

        def election
          @election ||= collection.find(params.expect(:id))
        end

        def collection
          @collection ||= Decidim::SecureElections::Election.where(component: current_component)
        end

        # --- Decidim::Admin::Filterable -------------------------------------

        def base_query
          collection.order(created_at: :desc)
        end

        def search_field_predicate
          :search_text_cont
        end

        def filters
          [:with_any_state, :published_at_null]
        end

        def filters_with_values
          {
            with_any_state: %w(upcoming ongoing finished),
            published_at_null: [true, false]
          }
        end

        # --- Decidim::Admin::HasTrashableResources --------------------------

        def trashable_deleted_resource_type
          :election
        end

        def trashable_deleted_collection
          @trashable_deleted_collection ||= paginate(collection.only_deleted.deleted_at_desc)
        end

        def trashable_deleted_resource
          @trashable_deleted_resource ||= Decidim::SecureElections::Election.with_deleted.find_by(component: current_component, id: params[:id])
        end
      end
    end
  end
end
