# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # What the redesigned Census tab needs on top of upstream's controller.
      #
      # The page itself is `app/views/decidim/elections/admin/census/edit.html.erb`
      # in this engine, which takes precedence over upstream's file of the same
      # name. Engine view paths are prepended in load order, and this module is
      # not a declared dependency of upstream's, so the path is prepended here
      # explicitly rather than trusted to come out on top by itself.
      #
      # Everything below is presentation data, exposed lazily as helpers so it
      # is computed at render time — `update` builds its own `@form` inside the
      # action, after any `before_action` would have run.
      module CensusPage
        extend ActiveSupport::Concern

        included do
          prepend_view_path Decidim::Elections::Vocdoni::Engine.root.join("app", "views")

          helper Decidim::Elections::Vocdoni::Admin::CensusSetupHelper
          helper_method :internal_users_form, :verification_rows, :eligible_count, :census_voters_count

          # Upstream's `update` reads `election.census.admin_form` with no
          # guard, so a save that names no census type raises. The old page
          # could not produce one (its Save button was hidden until a type was
          # picked); the new one keeps the button reachable, so the case is
          # answered here instead.
          # `update` is upstream's action, on the controller this is included
          # onto — the cop cannot see it from here.
          before_action :ensure_census_type_chosen, only: :update # rubocop:disable Rails/LexicallyScopedActionFilter
        end

        private

        def ensure_census_type_chosen
          return if election.census.present?

          flash[:alert] = I18n.t("census_setup.no_choice", scope: "decidim.elections.vocdoni.admin")
          # The tab is a member route on the election (`get "census"`), not the
          # `edit` of the singular resource that also answers this PATCH.
          redirect_to Decidim::EngineRouter.admin_proxy(current_component).census_election_path(election)
        end

        # The "Registered participants" set-up block is always rendered, so it
        # always needs a form object: the one the action built when that is the
        # census being saved, otherwise one rebuilt from what is stored.
        def internal_users_form
          @internal_users_form ||=
            if @form.is_a?(::Decidim::Elections::Admin::Censuses::InternalUsersForm)
              @form
            else
              form(::Decidim::Elections::Admin::Censuses::InternalUsersForm)
                .from_params(stored_internal_users_settings, election:)
            end
        end

        # Only the keys that form knows; a file census keeps its own settings
        # under different names.
        def stored_internal_users_settings
          return {} unless election.census_manifest.to_s == "internal_users"

          election.census_settings.to_h.slice("authorization_handlers")
        end

        # One row per verification the organisation offers, in the order
        # Decidim registers them. `granted` is a count query each: there are a
        # handful of workflows, and the number is the whole point of the row.
        def verification_rows
          @verification_rows ||= internal_users_form.available_authorizations.map do |workflow|
            {
              workflow:,
              name: workflow.name.to_s,
              granted: authorized_users_count([workflow.name.to_s])
            }
          end
        end

        # How many people could vote with the verifications currently ticked —
        # the same query the `internal_users` census runs.
        def eligible_count
          @eligible_count ||= authorized_users_count(internal_users_form.authorization_handlers_names.compact_blank)
        end

        def census_voters_count
          @census_voters_count ||= ::Decidim::Elections::Voter.where(election:).count
        end

        def authorized_users_count(handlers)
          ::Decidim::AuthorizedUsers.new(organization: current_organization, handlers:, strict: true).query.count
        end
      end
    end
  end
end
