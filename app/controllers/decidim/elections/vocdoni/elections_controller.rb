# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    # The public election list and the election page.
    class ElectionsController < Decidim::Elections::Vocdoni::ApplicationController
      include Decidim::Paginable
      include ActionView::Helpers::NumberHelper

      # How long a cached tally is considered fresh enough to serve without
      # asking for a refresh.
      RESULTS_FRESHNESS = 30.seconds

      helper_method :paginated_elections, :results_payload

      before_action :ensure_readable, only: [:show, :status]

      def index; end

      def show; end

      # Cheap, Decidim-local JSON polled by the election page.
      #
      # This endpoint deliberately performs no Vocdoni call: it reads the
      # denormalized counters and the cached tally that a background job keeps
      # up to date (ARCHITECTURE §0.5). If the cache is stale we ask the job to run
      # again — asynchronously — and say so in the payload rather than blocking
      # the request on the API.
      def status
        refresh_results_if_stale

        render json: results_payload
      end

      private

      def ensure_readable
        enforce_permission_to(:read, :election, election:)
      end

      def paginated_elections
        @paginated_elections ||= paginate(elections)
      end

      def results_payload
        {
          id: election.id,
          state: election_state,
          ongoing: voting_open?,
          votes_count: election.votes_count,
          votes_count_text: t("votes_count", scope: "decidim.elections.vocdoni.elections.results", count: election.votes_count),
          census_size: election.census_size,
          synced_at: election.results_synced_at&.iso8601,
          synced_at_text: last_updated_text,
          stale: results_stale?,
          final: final_results?,
          questions: questions.map { |question| question_payload(question) }
        }
      end

      # `question.votes_count` is the number of ballots cast, not the sum of the
      # per-answer tallies: on a multichoice question one ballot contributes to
      # several answers, so summing them would inflate the total and skew every
      # percentage.
      def question_payload(question)
        {
          id: question.id,
          votes_count: question.votes_count,
          votes_count_text: t("votes_count", scope: "decidim.elections.vocdoni.elections.results", count: question.votes_count),
          answers: question.answers.map { |answer| answer_payload(answer) }
        }
      end

      def answer_payload(answer)
        percent = answer.votes_percent

        {
          id: answer.id,
          votes_count: answer.votes_count.to_i,
          votes_count_text: t("votes_count", scope: "decidim.elections.vocdoni.elections.results", count: answer.votes_count.to_i),
          percent: percent.round(2),
          percent_text: number_to_percentage(percent, precision: 1)
        }
      end

      # Whether every question's tally is final on chain. `results_cache` is
      # written only by `SyncResultsJob`, which keys questions by their Decidim
      # id and flags finality as `"final"`.
      def final_results?
        cached = election.results_cache
        return false unless cached.is_a?(Hash)

        questions_cache = cached["questions"]
        return false if questions_cache.blank?

        entries = questions_cache.is_a?(Hash) ? questions_cache.values : Array(questions_cache)
        entries.all? { |question| question["final"] }
      end

      # Kept identical to `ElectionResultsCell#last_updated_text`: the page is
      # server-rendered once and then updated in place, so the two have to be
      # the same sentence or the figure would appear to change its meaning the
      # first time the poller answers.
      def last_updated_text
        return t("decidim.elections.vocdoni.elections.results.not_synced_yet") if election.results_synced_at.blank?

        t("decidim.elections.vocdoni.elections.results.last_updated",
          time: l(election.results_synced_at, format: :decidim_short))
      end

      def results_stale?
        return true if election.results_synced_at.blank?

        election.results_synced_at < RESULTS_FRESHNESS.ago
      end

      # Reading the tally is a slow SaaS call, so it never happens inside a web
      # request (ARCHITECTURE §0.5): we serve the cached columns and ask the job to
      # refresh them in the background. The next poll picks up the new values.
      #
      # The guard is not an optimisation. This endpoint is public and
      # unauthenticated, every viewer of a live election polls it, and
      # `results_synced_at` only moves when the job *succeeds* — so while the
      # SaaS API is unreachable, `results_stale?` stays true and every poll from
      # every viewer enqueues another job, each of which retries three times.
      # That is an amplifier pointed at our own API, built out of ordinary
      # traffic. One marker with a short TTL means at most one job in flight per
      # election however many people are watching.
      #
      # It fails open: a cache that cannot be written (`:null_store`, a Redis
      # outage) leaves the module behaving exactly as it did before, which is
      # the right way round for a control that only exists to shed load.
      def refresh_results_if_stale
        return unless results_stale?
        return unless election.on_chain?
        return unless claim_results_refresh?

        Decidim::Elections::Vocdoni::SyncResultsJob.perform_later(election.id)
      end

      # True for the first caller within the freshness window, false for the
      # rest. `write(unless_exist:)` is atomic in every cache store Decidim
      # ships with a shared backend.
      def claim_results_refresh?
        Rails.cache.write(
          "decidim/elections/vocdoni/results_refresh/#{election.id}",
          true,
          expires_in: RESULTS_FRESHNESS,
          unless_exist: true
        )
      rescue StandardError
        true
      end

      def add_breadcrumb_item
        return {} if params[:id].blank?

        {
          label: translated_attribute(election.title),
          url: Decidim::EngineRouter.main_proxy(current_component).election_path(election),
          active: false
        }
      end
    end
  end
end
end
