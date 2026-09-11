# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    # Live tally of an election.
    #
    # Everything rendered here comes from the denormalized counters that a
    # background job refreshes from `results_cache` — never from a call to the
    # Vocdoni API inside the request (ARCHITECTURE §0.5). The markup carries
    # `data-` hooks that `election_status.js` updates in place while polling the
    # component's own `status` endpoint.
    class ElectionResultsCell < Decidim::ViewModel
      include Decidim::LayoutHelper
      include ActionView::Helpers::NumberHelper

      alias election model

      def show
        return if questions.blank?

        render
      end

      private

      def questions
        @questions ||= options[:questions] || election.questions.includes(:answers)
      end

      def votes_count_text(count)
        t("votes_count", scope: "decidim.elections.vocdoni.elections.results", count: count.to_i)
      end

      def status_url
        options[:status_url]
      end

      # A question that is still secret until the end has no meaningful tally to
      # show: saying "0 votes" would be a lie.
      def secret?(question)
        question.secret_until_the_end && !final?
      end

      # `results_cache` is written only by `SyncResultsJob`, which keys questions
      # by their Decidim id and flags finality as `"final"`.
      def final?
        cached = election.results_cache
        return false unless cached.is_a?(Hash)

        questions_cache = cached["questions"]
        return false if questions_cache.blank?

        entries = questions_cache.is_a?(Hash) ? questions_cache.values : Array(questions_cache)
        entries.all? { |question| question["final"] }
      end

      # The same sentence the admin monitor shows, so that both sides of the
      # module describe the freshness of a tally in one vocabulary.
      # `ElectionsController#results_payload` reproduces it for the poller.
      def last_updated_text
        return t("decidim.elections.vocdoni.elections.results.not_synced_yet") if election.results_synced_at.blank?

        t("decidim.elections.vocdoni.elections.results.last_updated",
          time: l(election.results_synced_at, format: :decidim_short))
      end
    end
  end
end
end
