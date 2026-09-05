# frozen_string_literal: true

module Decidim
  module SecureElections
    # Serializes an election together with its questions, its answers and the
    # tally, for the `election_results` export declared in
    # `lib/decidim/secure_elections/component.rb`.
    #
    # Two things make this serializer different from a plain dump of the record:
    #
    # 1. **It never calls the API.** Every figure comes from `results_cache` and
    #    from the denormalized counters that `Decidim::SecureElections::SyncResultsJob`
    #    maintains, so exporting is a pure database read (ARCHITECTURE §0.5).
    #
    # 2. **It carries the on-chain identifiers.** An exported tally that cannot
    #    be checked against the chain is just a number in a spreadsheet, which
    #    defeats the point of running the ballot on a verifiable backend. The
    #    export therefore includes the process id and, per question, the Vochain
    #    election id (`vocdoni_upstream_id`) that the ballots were actually cast
    #    against, so any third party can recompute the result from the chain.
    #
    # Questions and answers are serialized as position-keyed hashes rather than
    # arrays because `Decidim::Exporters::CSV` flattens a nested hash into
    # `questions/1/title/en` columns but collapses an array into a single
    # unusable cell.
    class ElectionResultsSerializer < Decidim::Exporters::Serializer
      # @param election [Decidim::SecureElections::Election]
      def initialize(election)
        @election = election
      end

      # @return [Hash] the serialized election.
      def serialize
        {
          id: election.id,
          reference: election.reference,
          title: election.title,
          description: election.description,
          participatory_space: {
            id: election.participatory_space.id,
            url: Decidim::ResourceLocatorPresenter.new(election.participatory_space).url
          },
          component: { id: component.id },
          url: Decidim::ResourceLocatorPresenter.new(election).url,
          status: election.status,
          published_at: election.published_at,
          start_at: election.start_at,
          end_at: election.end_at,
          verification:,
          results:,
          questions:
        }
      end

      private

      attr_reader :election
      alias resource election

      # Everything a third party needs to find this election on the chain and
      # recompute the tally without trusting this export.
      def verification
        {
          vocdoni_process_id: election.vocdoni_process_id,
          vocdoni_chain_id: election.vocdoni_chain_id,
          on_chain: election.on_chain?,
          explorer_url: explorer_process_url
        }
      end

      def results
        {
          synced_at: election.results_synced_at,
          final: final?,
          census_size: election.census_size,
          votes_count: election.votes_count,
          turnout_percent: election.turnout&.round(2)
        }
      end

      def questions
        election.questions.each_with_index.to_h do |question, index|
          [(index + 1).to_s, question_data(question, index)]
        end
      end

      # `question.votes_count` is the number of ballots cast for that question,
      # not the sum of its answers: on a multichoice question one ballot adds to
      # several answers at once.
      def question_data(question, index)
        {
          id: question.id,
          position: index + 1,
          title: question.title,
          description: question.description,
          question_type: question.question_type,
          secret_until_the_end: question.secret_until_the_end,
          max_choices: question.max_choices,
          min_choices: question.min_choices,
          vocdoni_question_id: question.vocdoni_question_id,
          # The Vochain election id the ballots were signed against — this, not
          # the process id, is what identifies the tally on chain.
          vocdoni_upstream_id: question.vocdoni_upstream_id,
          explorer_url: explorer_question_url(question),
          status: question.vocdoni_status,
          final: question_final?(question),
          votes_count: question.votes_count,
          answers: answers_for(question)
        }
      end

      def answers_for(question)
        question.answers.each_with_index.to_h do |answer, index|
          [(index + 1).to_s, answer_data(answer)]
        end
      end

      def answer_data(answer)
        {
          id: answer.id,
          # The 0-based integer actually encoded in the ballot.
          value: answer.value,
          title: answer.title,
          votes_count: answer.votes_count.to_i,
          votes_percent: answer.votes_percent.round(2)
        }
      end

      # ---------------------------------------------------------------------
      # Cached tally reads
      # ---------------------------------------------------------------------

      def results_cache
        cache = election.results_cache
        cache.is_a?(Hash) ? cache : {}
      end

      def question_final?(question)
        results_cache.dig("questions", question.id.to_s, "final") == true
      end

      # An election's tally is final only when every question's is.
      def final?
        return false if election.questions.empty?

        election.questions.all? { |question| question_final?(question) }
      end

      # ---------------------------------------------------------------------
      # Explorer links
      # ---------------------------------------------------------------------

      def explorer_base
        @explorer_base ||= Decidim::SecureElections.explorer_url.to_s.sub(%r{/+\z}, "")
      end

      def explorer_process_url
        return nil if election.vocdoni_process_id.blank? || explorer_base.blank?

        "#{explorer_base}/processes/show/#/#{election.vocdoni_process_id}"
      end

      def explorer_question_url(question)
        return nil if question.vocdoni_upstream_id.blank? || explorer_base.blank?

        "#{explorer_base}/processes/show/#/#{question.vocdoni_upstream_id}"
      end
    end
  end
end
