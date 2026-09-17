# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Admin
      # This is upstream's own controller. This engine takes it over with a
      # view override (`Decidim::Elections::Vocdoni::CensusPage`, prepended
      # in `phase_4_spike.rb`) rather than a controller of its own.
      #
      # Only the page itself is exercised here. What a save does is covered
      # by `spec/commands/decidim/elections/admin/process_census_spec.rb`:
      # upstream redirects to a route mounted once per participatory-space
      # type, which a controller spec cannot resolve, and the command is
      # where the behaviour actually lives.
      describe CensusController do
        let(:organization) { create(:organization, available_authorizations: %w(dummy_authorization_handler)) }
        let(:component) { create(:elections_component, organization:) }
        let(:election) { create(:election, component:) }
        let(:current_user) { create(:user, :admin, :confirmed, organization:) }

        before do
          request.env["decidim.current_organization"] = organization
          request.env["decidim.current_participatory_space"] = component.participatory_space
          request.env["decidim.current_component"] = component
          sign_in current_user
        end

        describe "GET edit" do
          # This is the one thing worth going through the views for: proving
          # this engine's `app/views/decidim/elections/admin/census/edit.html.erb`
          # is the one that renders, not upstream's own file of the same name.
          # That is a matter of view-path load order, not of what the
          # controller returns, so only the rendered body can show it.
          render_views

          it "renders this engine's page rather than upstream's" do
            get :edit, params: { id: election.id }

            expect(response).to be_successful
            expect(response.body).to include(I18n.t("legend", scope: "decidim.elections.vocdoni.admin.census_setup.choice"))
            expect(response.body).to include(I18n.t("legend", scope: "decidim.elections.vocdoni.admin.census_setup.registered"))
          end
        end

      end
    end
  end
end
