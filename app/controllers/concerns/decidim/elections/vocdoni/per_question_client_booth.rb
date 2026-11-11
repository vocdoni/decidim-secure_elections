# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Prepended onto upstream's `Decidim::Elections::PerQuestionVotesController`
      # (see engine.rb `extend_upstream`) so a `per_question` election runs
      # in Decidim's client-side booth with the `vocdoni` backend.
      #
      # Upstream's per-question flow is server-side: it casts each question
      # through `CastVotes` and tracks progress in the session. Here ballots
      # go from the browser to Vocdoni and the server never learns what was
      # cast, so progress is driven by the questions the admin has open:
      #
      # * the booth renders only the open questions (enabled, results not
      #   published); the adapter skips those the CSP says were already cast;
      # * with nothing open, the voter waits on upstream's waiting page;
      # * `waiting.json` also lists the open question ids, so a booth showing
      #   its receipt can reload as soon as the admin opens another question.
      module PerQuestionClientBooth
        extend ActiveSupport::Concern

        prepended do
          before_action :redirect_to_vocdoni_booth, only: [:show, :update], if: :vocdoni_client_booth?
          before_action :wait_for_open_question, only: :booth, if: :vocdoni_client_booth?
        end

        def waiting
          return super unless vocdoni_client_booth? && request.format.json?

          enforce_permission_to(:create, :vote, election:)
          action = waiting_for_next_question? ? nil : next_vote_step_action
          render json: { url: action ? url_for(**action) : nil, open_question_ids: open_questions.pluck(:id).map(&:to_s) }
        end

        private

        def vocdoni_client_booth?
          Decidim::Elections::Vocdoni::VotingBackend.active_for?(election)
        end

        def open_questions
          election.questions.enabled.unpublished_results
        end

        # Only the booth narrows the list: upstream's `question` lookup for
        # the other actions must still find closed questions.
        def questions
          return super unless action_name == "booth" && vocdoni_client_booth?

          @questions ||= open_questions
        end

        def waiting_for_next_question?
          return super unless vocdoni_client_booth?

          open_questions.none? && election.questions.unpublished_results.any?
        end

        def next_vote_step_action
          return super unless vocdoni_client_booth?
          return { action: :receipt } if election.questions.unpublished_results.none?
          return { action: :waiting } if open_questions.none?

          { action: :booth }
        end

        # The server-side question form would cast through `CastVotes`,
        # outside Vocdoni. The JSON status poll is read-only and left alone.
        def redirect_to_vocdoni_booth
          return if action_name == "show" && request.format.json?

          redirect_to(**next_vote_step_action)
        end

        def wait_for_open_question
          redirect_to(**next_vote_step_action) if open_questions.none?
        end
      end
    end
  end
end
