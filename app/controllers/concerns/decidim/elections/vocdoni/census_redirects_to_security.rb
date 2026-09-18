# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Prepended onto upstream's `Decidim::Elections::Admin::CensusController`
      # (see the `extend_upstream` initializer in `engine.rb`).
      #
      # Upstream hard-codes `redirect_to dashboard_election_path(election)`
      # inside `#update`. That skips the Security tab entirely — an admin who
      # clicks "Save and continue" on the Census tab lands on the Dashboard
      # without a chance to opt in to Vocdoni. Rewire the redirect target so
      # the wizard walks Census → Security → Dashboard.
      #
      # Done as an `after_action` that rewrites the `Location` header when
      # the response is a 302 pointing at the dashboard: cheaper than
      # duplicating upstream's whole `update` action (which would drift with
      # every upstream change to error handling, permissions or i18n keys).
      module CensusRedirectsToSecurity
        extend ActiveSupport::Concern

        included do
          after_action :route_census_save_through_security, only: :update
        end

        private

        def route_census_save_through_security
          return unless response.redirect?
          return unless (location = response.headers["Location"]).present?
          return unless location.include?("/dashboard")

          response.headers["Location"] = location.sub(%r{/dashboard(\z|\?)}, '/security\1')
        end
      end
    end
  end
end
