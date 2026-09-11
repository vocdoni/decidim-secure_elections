# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    module Admin
      describe CensusForm do
        subject(:form) { described_class.from_params(attributes).with_context(context) }

        let(:organization) { create(:organization) }
        let(:election) { create(:vocdoni_election) }
        let(:context) { { current_organization: organization, election: } }

        let(:attributes) do
          {
            census: {
              credentials: ["memberNumber"],
              two_factor_method: "off",
              weighted: false
            }
          }
        end

        it { is_expected.to be_valid }

        # The mistake this form exists to refuse: a census with nothing to
        # identify a voter by was accepted, and then let everybody through.
        context "when nothing identifies a voter" do
          before do
            attributes[:census][:credentials] = []
            attributes[:census][:two_factor_method] = "off"
          end

          it { is_expected.to be_invalid }

          it "explains what is missing" do
            form.valid?
            expect(form.errors[:credentials]).not_to be_empty
          end
        end

        # A second factor alone does identify somebody, so it is enough.
        context "when only two-factor verification is configured" do
          before do
            attributes[:census][:credentials] = []
            attributes[:census][:two_factor_method] = "email"
          end

          it { is_expected.to be_valid }
        end

        context "when more than three credentials are picked" do
          before { attributes[:census][:credentials] = %w(name surname memberNumber nationalId) }

          it { is_expected.to be_invalid }
        end

        # Email and phone are a second factor, not a credential (ARCHITECTURE §4c).
        context "when a two-factor field is offered as a credential" do
          before { attributes[:census][:credentials] = ["email"] }

          it { is_expected.to be_invalid }
        end

        context "when the two-factor method is not one of the four" do
          before { attributes[:census][:two_factor_method] = "carrier_pigeon" }

          it { is_expected.to be_invalid }
        end

        describe "#two_fa_fields" do
          # The mapping is the Vocdoni app's (`VoterAuthentication/utils.ts`)
          # and the two must not drift.
          {
            "off" => [],
            "email" => ["email"],
            "sms" => ["phone"],
            "voter_choice" => %w(email phone)
          }.each do |method, fields|
            it "maps #{method} to #{fields.inspect}" do
              attributes[:census][:two_factor_method] = method

              expect(form.two_fa_fields).to eq(fields)
            end
          end
        end

        describe "#security_level" do
          it "is weak with a single credential and no second factor" do
            expect(form.security_level).to eq("weak")
          end

          it "is mid with three credentials and no second factor" do
            attributes[:census][:credentials] = %w(name surname memberNumber)

            expect(form.security_level).to eq("mid")
          end

          it "is strong whenever a second factor is on" do
            attributes[:census][:two_factor_method] = "sms"

            expect(form.security_level).to eq("strong")
          end
        end

        describe "#credentials_advice" do
          it "says nothing when nothing is picked" do
            attributes[:census][:credentials] = []
            attributes[:census][:two_factor_method] = "email"

            expect(form.credentials_advice).to be_nil
          end

          it "nudges for a second credential when only one is picked" do
            expect(form.credentials_advice).to eq(:recommend)
          end

          it "is reassuring from two credentials on" do
            attributes[:census][:credentials] = %w(name surname)

            expect(form.credentials_advice).to eq(:good)
          end
        end

        describe "#map_model" do
          subject(:form) { described_class.from_model(election).with_context(context) }

          let(:election) { create(:vocdoni_election, census_auth_fields: ["nationalId"], census_two_fa_fields: %w(email phone), weighted: true) }

          it "reads the method back from the stored fields" do
            expect(form.credentials).to eq(["nationalId"])
            expect(form.two_factor_method).to eq("voter_choice")
            expect(form.weighted).to be(true)
          end
        end
      end
    end
  end
end
end
