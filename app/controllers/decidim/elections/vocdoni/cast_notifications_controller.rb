# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # `POST /elections/:election_id/vocdoni_cast_notification`, called by the
      # booth adapter after a successful cast so a `real_time` election's
      # tally is pulled from Vocdoni right away (see {LiveResultsSync}).
      #
      # The request says only "this voter cast in election X": the body is
      # ignored and the vote itself is never seen here. It can at most start
      # or prolong one results-sync chain for the election, so the guards are
      # the same session the booth runs on (census session + CSRF) and a rate
      # limit per voter.
      class CastNotificationsController < Decidim::Elections::ApplicationController
        include Decidim::Elections::UsesCensusAccess

        # Generous for one voter, who casts once per question at most.
        RATE_LIMIT = 10
        RATE_LIMIT_WINDOW = 10.minutes

        def create
          return head(:forbidden) unless allowed_to?(:create, :vote, election:) && session_authenticated?
          return head(:too_many_requests) unless within_rate_limit?

          LiveResultsSync.request!(election.vocdoni_process) if LiveResultsSync.applies_to?(election)
          head :no_content
        end

        private

        # Keyed on the census identity rather than the session, so a new
        # session does not reset the count. `Rails.cache` is per host app; a
        # cache shared across web processes makes the limit exact.
        def within_rate_limit?
          key = "decidim_vocdoni/cast_notification/#{election.id}/#{Digest::SHA256.hexdigest(voter_uid.to_s)}"
          count = Rails.cache.increment(key, 1, expires_in: RATE_LIMIT_WINDOW)
          count.nil? || count <= RATE_LIMIT
        end
      end
    end
  end
end
