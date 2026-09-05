# frozen_string_literal: true

require "spec_helper"

module Decidim
  module SecureElections
    module Admin
      describe CreateElection do
        subject(:command) { described_class.new(form) }

        let(:organization) { create(:organization, available_locales: [:en]) }
        let(:participatory_space) { create(:participatory_process, organization:) }
        let(:component) { create(:vocdoni_component, participatory_space:) }
        let(:user) { create(:user, :admin, :confirmed, organization:) }

        let(:context) do
          { current_organization: organization, current_component: component, current_user: user }
        end

        # Step 1 of the wizard writes the details and nothing else. The ballot,
        # the census and the schedule are steps of their own, with their own
        # commands.
        let(:attributes) do
          {
            election: {
              title_en: "General assembly 2026",
              description_en: "<p>The yearly vote.</p>"
            }
          }
        end

        let(:form) { ElectionForm.from_params(attributes).with_context(context) }

        it "broadcasts ok" do
          expect { command.call }.to broadcast(:ok)
        end

        it "creates a draft election from a title alone" do
          expect { command.call }.to change(Decidim::SecureElections::Election, :count).by(1)

          election = Decidim::SecureElections::Election.last
          expect(election.status).to eq("draft")
          expect(election.questions).to be_empty
        end

        it "leaves the schedule to the calendar step" do
          command.call

          election = Decidim::SecureElections::Election.last
          expect(election.start_at).to be_nil
          expect(election.end_at).to be_nil
        end

        it "completes the details step and unlocks the ballot, and nothing beyond it" do
          command.call

          election = Decidim::SecureElections::Election.last
          expect(election).to be_details_complete
          expect(election.step_reachable?(:questions)).to be(true)
          expect(election.step_reachable?(:census)).to be(false)
        end

        it "writes nothing to the blockchain" do
          command.call

          expect(Decidim::SecureElections::Election.last.vocdoni_process_id).to be_nil
        end

        context "when the title is blank" do
          before { attributes[:election][:title_en] = "" }

          it "leaves no draft behind" do
            expect { command.call }.to broadcast(:invalid)
            expect(Decidim::SecureElections::Election.count).to be_zero
          end
        end
      end
    end
  end
end
