# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Step 2 of the wizard: the ballot.
      #
      # Questions **and** their options are on this one screen: adding an option
      # must not cost a page load, so the whole ballot is one nested form,
      # edited in the browser and submitted in a single request.
      #
      # Locked until the details step is complete, and read-only once the
      # process is on chain — by then each question is its own Vochain election
      # and its wording is signed by every voter.
      class QuestionsController < Admin::ApplicationController
        wizard_step :questions

        def edit
          enforce_permission_to(:read, :question, election:)

          @form = form(Decidim::Elections::Vocdoni::Admin::ElectionQuestionsForm).from_model(election, election:)
        end

        def update
          enforce_permission_to(:update, :question, election:)

          @form = form(Decidim::Elections::Vocdoni::Admin::ElectionQuestionsForm).from_params(params, election:)

          Decidim::Elections::Vocdoni::Admin::UpdateElectionQuestions.call(@form, election) do
            on(:ok) do
              flash[:notice] = I18n.t("questions.update.success", scope: "decidim.elections.vocdoni.admin")
              redirect_to next_step_path
            end

            on(:invalid) do
              flash.now[:alert] = I18n.t("questions.update.invalid", scope: "decidim.elections.vocdoni.admin")
              @form.ensure_default_questions!
              render action: "edit", status: :unprocessable_content
            end
          end
        end

        # Draft autosave — the same save answered as JSON, so a ballot half
        # written is not a ballot lost.
        #
        # The response hands back the database id of every question and option
        # that did not have one; otherwise the next autosave would create them
        # all over again.
        def autosave
          # Asked without raising, so that a refusal can be answered in the
          # format the caller asked for. See `autosave_refused`.
          return autosave_refused unless allowed_to?(:update, :question, election:)

          @form = form(Decidim::Elections::Vocdoni::Admin::ElectionQuestionsForm).from_params(params, election:)

          Decidim::Elections::Vocdoni::Admin::UpdateElectionQuestions.call(@form, election) do
            on(:ok) do
              render json: { saved: true, saved_at: Time.current.iso8601, questions: @form.saved_ids }, status: :ok
            end

            on(:invalid) do
              render json: { saved: false, errors: @form.errors.full_messages }, status: :unprocessable_content
            end
          end
        end

        private

        def next_step_path
          election.reload
          return vocdoni_step_path(election, :census) if election.step_reachable?(:census)

          vocdoni_step_path(election, :questions)
        end
      end
    end
  end
end
end
