# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Saves step 2 of the wizard: the whole ballot, in one transaction.
      #
      # The step submits every question and every option each time, so this is a
      # reconciliation rather than a series of edits — see
      # `SavesElectionQuestions`, which does the actual work and is what keeps
      # the on-chain choice values contiguous.
      #
      # Refuses outright once the process exists on chain: the questions are
      # separate Vochain elections by then and cannot be rewritten.
      class UpdateElectionQuestions < Decidim::Commands::UpdateResource
        include Decidim::Elections::Vocdoni::Admin::SavesElectionQuestions

        private

        alias election resource

        def invalid?
          return true unless election.editable?

          form.invalid?
        end

        # The ballot lives in the `questions` and `answers` tables, not in
        # columns of the election. Nothing is assigned here; `run_after_hooks`
        # does all of it, inside the same transaction, so a ballot that cannot
        # be saved rolls the whole edit back.
        def attributes
          {}
        end

        def run_after_hooks
          save_questions!(election)
        end

        def extra_params = { visibility: "admin-only" }
      end
    end
  end
end
end
