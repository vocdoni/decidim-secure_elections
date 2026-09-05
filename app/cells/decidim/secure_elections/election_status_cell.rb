# frozen_string_literal: true

module Decidim
  module SecureElections
    # Renders the lifecycle badge of an election, and — as a class method — owns
    # the derivation of that lifecycle.
    #
    # Keeping the derivation in one place matters: the card, the badge, the
    # aside CTA and the controllers all have to agree on what "ongoing" means,
    # and an election that is `ready` upstream but has not reached its start
    # time is *not* ongoing.
    #
    # Only columns documented in ARCHITECTURE §4b are read; there is no API call.
    class ElectionStatusCell < Decidim::ViewModel
      include Decidim::LayoutHelper

      ICONS = {
        draft: "draft-line",
        publishing: "loader-line",
        scheduled: "calendar-schedule-line",
        ongoing: "play-circle-line",
        paused: "pause-circle-line",
        ended: "stop-circle-line",
        results: "bar-chart-box-line",
        canceled: "close-circle-line"
      }.freeze

      # Statuses that name the lifecycle on their own. For these the calendar
      # is not consulted at all: an election someone paused is paused whatever
      # the clock says, and one still in draft has no schedule worth reading.
      SELF_EVIDENT_STATUSES = {
        "canceled" => :canceled,
        "results" => :results,
        "draft" => :draft,
        "publishing" => :publishing,
        "paused" => :paused,
        "ended" => :ended
      }.freeze

      # Derives the lifecycle of an election from its stored status and its
      # calendar.
      #
      # This is the label-level view of the same truth as `Election#ongoing?`,
      # which stays the single authority on whether a ballot may be cast: this
      # method returns `:ongoing` in exactly the cases where that predicate is
      # true, and names the reason in every other case. It reads only the
      # columns of ARCHITECTURE §4b, so it never triggers a query or an API call.
      #
      # @param election [Decidim::SecureElections::Election]
      # @return [Symbol] one of the keys of {ICONS}
      def self.state_for(election)
        status = election.status.to_s
        return SELF_EVIDENT_STATUSES[status] if SELF_EVIDENT_STATUSES.has_key?(status)

        # Only `ready` gets this far: on chain and not stopped by anyone, so
        # the calendar is what decides whether the ballot is open, still to
        # come, or over.
        return :ended if election.end_at.present? && election.end_at <= Time.current
        return :scheduled if election.start_at.present? && election.start_at > Time.current

        status == "ready" ? :ongoing : :draft
      end

      def show
        render
      end

      private

      alias election model

      def state
        @state ||= self.class.state_for(election)
      end

      def label
        t(state, scope: "decidim.secure_elections.elections.states")
      end

      def icon_name
        ICONS.fetch(state, "question-line")
      end
    end
  end
end
