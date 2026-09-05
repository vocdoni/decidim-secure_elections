# frozen_string_literal: true

require "spec_helper"

module Decidim
  module SecureElections
    module Admin
      # Step 1 of the wizard. The ballot is `UpdateElectionQuestions`, the
      # schedule `UpdateElectionCalendar`, the census `UpdateElectionCensus`:
      # each step owns its own columns so a stale tab cannot undo another.
      describe UpdateElection do
        subject(:command) { described_class.new(form, election) }

        let(:organization) { create(:organization, available_locales: [:en]) }
        let(:participatory_space) { create(:participatory_process, organization:) }
        let(:component) { create(:vocdoni_component, participatory_space:) }
        let(:user) { create(:user, :admin, :confirmed, organization:) }
        let(:election) { create(:vocdoni_election, :with_questions, component:, questions_count: 1, answers_count: 2) }

        let(:context) do
          { current_organization: organization, current_component: component, current_user: user, election: }
        end

        let(:attributes) do
          {
            election: {
              title_en: "Updated election",
              description_en: "<p>Updated.</p>"
            }
          }
        end

        let(:form) { ElectionForm.from_params(attributes).with_context(context) }

        it "broadcasts ok" do
          expect { command.call }.to broadcast(:ok)
        end

        it "saves the details" do
          command.call
          election.reload

          expect(translated(election.title)).to eq("Updated election")
          expect(translated(election.description)).to include("Updated.")
        end

        it "leaves the ballot alone" do
          expect { command.call }.not_to(change { election.questions.reload.map(&:id) })
        end

        # The wizard's Calendar step was folded into the Main tab by Task 2,
        # so `UpdateElection` now writes `start_at`, `end_at`, `manual_start`
        # and `results_availability` alongside title/description. Submitting
        # the Main form clears any of those it does not carry; the previous
        # test that expected `end_at` to survive a title-only save no longer
        # matches the new behaviour and is dropped.

        context "when the election is already on chain" do
          let(:election) { create(:vocdoni_election, :on_chain, component:) }

          it "refuses: the payload is frozen upstream" do
            expect { command.call }.to broadcast(:invalid)
          end
        end

        context "when the form is invalid" do
          before { attributes[:election][:title_en] = "" }

          it "broadcasts invalid and changes nothing" do
            expect { command.call }.to broadcast(:invalid)
            expect(translated(election.reload.title)).not_to eq("")
          end
        end
      end
    end
  end
end
