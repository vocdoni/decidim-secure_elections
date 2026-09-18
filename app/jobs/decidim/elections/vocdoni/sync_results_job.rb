# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    # Reads the tally from the API and stores it locally.
    #
    # This is the only writer of `results_cache`. Everything that displays
    # results — the admin monitor, the public election page, the exporter —
    # reads that column, so a page view never costs an upstream request no
    # matter how many people are watching (ARCHITECTURE §0.5).
    class SyncResultsJob < ApplicationJob
      queue_as :vocdoni

      retry_on Decidim::Elections::Vocdoni::ApiError, wait: :polynomially_longer, attempts: 3

      def perform(election_id)
        @election = Decidim::Elections::Vocdoni::Election.find_by(id: election_id)
        return if election.blank? || election.vocdoni_process_id.blank?

        Decidim::Elections::Vocdoni.validate_configuration!

        # Not coerced with `to_h`: some deployments answer with a bare array of
        # per-question results.
        payload = client.elections.results(election.vocdoni_process_id)
        store!(build_cache(payload))
      rescue StandardError => e
        record_failure!(election, e)
        raise
      end

      private

      def store!(cache)
        Decidim::Elections::Vocdoni::Election.transaction do
          election.questions.each do |question|
            tallies = cache.dig("questions", question.id.to_s, "answers") || {}
            question.answers.each do |answer|
              votes = tallies[answer.id.to_s].to_i
              next if answer.votes_count == votes

              answer.update_columns(votes_count: votes) # rubocop:disable Rails/SkipsModelValidations
            end
          end

          attributes = {
            results_cache: cache,
            results_synced_at: Time.current,
            votes_count: cache["votes_count"].to_i
          }
          attributes[:census_size] = cache["census_size"] if cache["census_size"].to_i.positive?
          attributes[:status] = cache["status"] if cache["status"].present?

          election.update!(attributes)
        end
      end

      # ---------------------------------------------------------------------
      # Parsing
      #
      # The exact tally envelope is not pinned down upstream, so the parser
      # is defensive: it accepts the shapes the API is known to use and degrades
      # to zeroes rather than raising, because a malformed tally must never take
      # the monitor page down.
      # ---------------------------------------------------------------------

      def build_cache(payload)
        entries = remote_entries(payload)

        questions = {}
        election.questions.each_with_index do |question, index|
          entry = entry_for(entries, question, index)
          questions[question.id.to_s] = question_cache(question, entry)
        end

        {
          "synced_at" => Time.current.iso8601,
          "votes_count" => total_votes(payload, questions),
          "census_size" => census_size(payload, entries),
          "status" => Decidim::Elections::Vocdoni::Election.normalize_status(payload.is_a?(Hash) ? payload["status"] : nil),
          "questions" => questions
        }.compact
      end

      def question_cache(question, entry)
        tallies = choice_tallies(entry)

        answers = question.answers.to_h { |answer| [answer.id.to_s, tallies[answer.value].to_i] }

        {
          "votes_count" => (entry && (entry["voteCount"] || entry["votesCount"]))&.to_i || answers.values.sum,
          "status" => Decidim::Elections::Vocdoni::Question.normalize_status(entry && entry["status"]) || question.vocdoni_status,
          "final" => entry && entry["finalResults"],
          "answers" => answers
        }.compact
      end

      def remote_entries(payload)
        candidates = if payload.is_a?(Array)
                       payload
                     else
                       payload["results"] || payload["questions"] || payload["questionResults"]
                     end

        Array(candidates).grep(Hash)
      end

      # Match by the ids we already know before falling back to position.
      def entry_for(entries, question, index)
        return nil if entries.empty?

        entry_matching(entries, question.vocdoni_upstream_id, "upstreamId", "electionId") ||
          entry_matching(entries, question.vocdoni_question_id, "questionId", "id") ||
          entries[index]
      end

      # The first entry any of whose `keys` carries `value`.
      #
      # A blank `value` never matches, so a question that has not been
      # published yet falls straight through to the next strategy rather than
      # matching an entry whose key happens to be missing too.
      def entry_matching(entries, value, *keys)
        return nil if value.blank?

        entries.find { |entry| entry.values_at(*keys).compact.map(&:to_s).include?(value) }
      end

      # Vochain tallies come back as an array of per-choice counts, sometimes
      # wrapped in an extra array (one entry per ballot field) and sometimes as
      # strings holding big numbers.
      def choice_tallies(entry)
        return [] if entry.blank?

        raw = entry["results"] || entry["choices"] || entry["values"] || entry["tally"]
        raw = raw.first if raw.is_a?(Array) && raw.first.is_a?(Array)

        Array(raw).map { |value| value.is_a?(Hash) ? value["value"].to_i : value.to_i }
      end

      # Each question is its own Vochain election, so a voter contributes one
      # vote per question. The election-wide figure is therefore the busiest
      # question, not the sum.
      def total_votes(payload, questions)
        explicit = payload.is_a?(Hash) ? (payload["voteCount"] || payload["votesCount"] || payload["totalVotes"]) : nil
        return explicit.to_i if explicit.present?

        questions.values.map { |question| question["votes_count"].to_i }.max.to_i
      end

      # The tally endpoint reports the census size per question, as `maxVoters`.
      def census_size(payload, entries)
        explicit = payload.is_a?(Hash) ? (payload["censusSize"] || payload.dig("census", "size")) : nil
        return explicit.to_i if explicit.present?

        entries.filter_map { |entry| entry["maxVoters"]&.to_i }.max
      end
    end
  end
end
end
