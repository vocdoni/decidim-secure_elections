# frozen_string_literal: true

module Decidim
  module SecureElections
    # Metadata shown on every election card: the lifecycle badge, the calendar
    # progress and the number of votes cast so far.
    class ElectionCardMetadataCell < Decidim::CardMetadataCell
      include Decidim::LayoutHelper
      include ActionView::Helpers::DateHelper

      alias election model

      def initialize(*)
        super

        @items.prepend(*election_items)
      end

      private

      def election_items
        [status_item, progress_item, votes_item].compact
      end

      def status_item
        { cell: "decidim/secure_elections/election_status", args: [election] }
      end

      def votes_item
        return if election.votes_count.to_i.zero?

        {
          text: t("votes_count", scope: "decidim.secure_elections.elections.results", count: election.votes_count),
          icon: "check-double-line"
        }
      end

      def start_date
        election.start_at&.to_time
      end

      def end_date
        election.end_at&.to_time
      end

      def current_date
        @current_date ||= Time.current.to_time
      end
    end
  end
end
