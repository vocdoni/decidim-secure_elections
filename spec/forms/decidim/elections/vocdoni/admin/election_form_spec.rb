# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Step 1 of the wizard: what the election *is*. A title is all it takes to
      # create one; the ballot, the census and the schedule are steps of their
      # own, with their own forms.
      describe ElectionForm do
        subject(:form) { described_class.from_params(attributes).with_context(context) }

        let(:organization) { create(:organization, available_locales: [:en]) }
        let(:participatory_space) { create(:participatory_process, organization:) }
        let(:component) { create(:vocdoni_component, participatory_space:) }
        let(:election) { nil }
        let(:context) { { current_organization: organization, current_component: component, election: } }

        let(:attributes) do
          {
            election: {
              title_en: "General assembly 2026",
              description_en: "<p>The yearly vote.</p>"
            }
          }
        end

        it { is_expected.to be_valid }

        it "asks for nothing but a title" do
          expect(described_class.from_params(election: { title_en: "Only a title" }).with_context(context)).to be_valid
        end

        context "when the title is missing" do
          before { attributes[:election][:title_en] = "" }

          it { is_expected.to be_invalid }
        end

        describe "the live stream URL" do
          before { attributes[:election][:stream_uri] = "not a url" }

          it { is_expected.to be_invalid }

          context "when it is a real URL" do
            before { attributes[:election][:stream_uri] = "https://www.youtube.com/watch?v=dQw4w9WgXcQ" }

            it { is_expected.to be_valid }
          end
        end

        describe "#editable?" do
          subject(:form) { described_class.from_model(election).with_context(context) }

          context "when the election is on chain" do
            let(:election) { create(:vocdoni_election, :on_chain, component:) }

            it { is_expected.not_to be_editable }
          end

          context "when it is still a draft" do
            let(:election) { create(:vocdoni_election, component:) }

            it { is_expected.to be_editable }
          end
        end
      end
    end
  end
end
end
