# frozen_string_literal: true

module Decidim
  module SecureElections
    # Shared election lookup for the public engine.
    #
    # Everything here reads only the columns documented in ARCHITECTURE §4b and
    # never calls the Vocdoni API: a public request must never fan out into an
    # upstream call (ARCHITECTURE §0.5).
    module NeedsElection
      extend ActiveSupport::Concern

      included do
        include Decidim::SecureElections::VotingPageLink

        helper_method :election, :elections, :questions, :election_state, :voting_open?, :exit_path
      end

      private

      # All the elections a visitor of this component may see.
      def elections
        @elections ||= Decidim::SecureElections::Election
                       .where(component: current_component)
                       .published
                       .order(start_at: :asc, id: :asc)
      end

      def election
        @election ||= elections.find(params[:election_id] || params[:id])
      end

      # `Question` and `Answer` both carry a positional default scope, so the
      # ballot order is the admin's order without restating it here.
      def questions
        @questions ||= election.questions.includes(:answers)
      end

      # The label-level lifecycle, used by the badge and by the "why can I not
      # vote" copy. It is a finer-grained view of the same truth as
      # `Election#ongoing?` — see `ElectionStatusCell.state_for`.
      def election_state(target = election)
        Decidim::SecureElections::ElectionStatusCell.state_for(target)
      end

      # True when the voting page should accept ballots right now. The model
      # owns this question; the UI must never reach a different conclusion.
      def voting_open?(target = election)
        target.ongoing?
      end

      # Where the voting page's "back to the election" control takes the voter.
      def exit_path
        @exit_path ||= election_path(election)
      end
    end
  end
end
