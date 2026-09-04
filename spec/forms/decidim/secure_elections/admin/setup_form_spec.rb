# frozen_string_literal: true

require "spec_helper"

module Decidim
  module SecureElections
    module Admin
      describe SetupForm do
        subject(:form) { described_class.from_params(attributes).with_context(context) }

        let(:organization) { create(:organization) }
        let(:election) { create(:vocdoni_election, :ready_to_publish) }
        let(:context) { { current_organization: organization, election: } }

        let(:attributes) do
          {
            setup: {
              confirm_irreversible: true
            }
          }
        end

        it { is_expected.to be_valid }

        context "when the acknowledgement is not ticked" do
          before { attributes[:setup][:confirm_irreversible] = false }

          it { is_expected.to be_invalid }
        end

        context "when the census is not configured" do
          let(:election) { create(:vocdoni_election, :with_questions) }

          it { is_expected.to be_invalid }

          it "explains that the census identifies nobody" do
            form.valid?
            expect(form.errors[:base].join).to include("census")
          end
        end

        context "when a question has fewer than two answers" do
          let(:election) do
            create(:vocdoni_election, :with_census).tap do |record|
              create(:vocdoni_question, :with_answers, answers_count: 1, election: record)
              record.reload
            end
          end

          it { is_expected.to be_invalid }
        end

        context "when there is no end date" do
          before { election.update!(end_time: nil) }

          it { is_expected.to be_invalid }
        end

        context "when the election is already on chain" do
          before { election.update!(vocdoni_process_id: "6885f0c2c1a4e2f0b1d33a01") }

          it { is_expected.to be_invalid }
        end

        context "when the module is not configured" do
          before { allow(Decidim::SecureElections).to receive(:api_key).and_return(nil) }

          it { is_expected.to be_invalid }
        end
      end
    end
  end
end
