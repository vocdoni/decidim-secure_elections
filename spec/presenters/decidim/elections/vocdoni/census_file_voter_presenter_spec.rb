# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Vocdoni
      describe CensusFileVoterPresenter do
        subject(:presenter) { described_class.new(voter) }

        let(:election) { create(:election) }
        let(:voter) { Decidim::Elections::Voter.create!(election:, data:) }

        describe "#identifier" do
          context "when there is a name and a surname" do
            let(:data) { { "name" => "Ada", "surname" => "Lovelace", "email" => "ada@example.org" } }

            it "prefers the full name" do
              expect(presenter.identifier).to eq("Ada Lovelace")
            end
          end

          context "when there is only a name" do
            let(:data) { { "name" => "Ada", "email" => "ada@example.org" } }

            it "falls back to the name alone" do
              expect(presenter.identifier).to eq("Ada")
            end
          end

          context "when there is no name at all" do
            let(:data) { { "email" => "ada@example.org" } }

            it "falls back to the email" do
              expect(presenter.identifier).to eq("ada@example.org")
            end
          end

          context "when there is no name and no email" do
            let(:data) { { "memberNumber" => "000123" } }

            it "falls back to the member number" do
              expect(presenter.identifier).to eq("000123")
            end
          end

          context "when only a national id is present" do
            let(:data) { { "nationalId" => "12345678Z" } }

            it "falls back to the national id" do
              expect(presenter.identifier).to eq("12345678Z")
            end
          end

          context "when only a phone is present" do
            let(:data) { { "phone" => "+34600000000" } }

            it "falls back to the phone" do
              expect(presenter.identifier).to eq("+34600000000")
            end
          end

          context "when none of the known fields are present" do
            let(:data) { { "weight" => "3" } }

            it "falls back to whatever the first stored value is" do
              expect(presenter.identifier).to eq("3")
            end
          end
        end

        describe "#value" do
          let(:data) { { "name" => "Ada", "token" => "A1B2C3" } }

          it "returns the stored value for an ordinary field" do
            expect(presenter.value("name")).to eq("Ada")
          end

          it "never shows the access code back" do
            expect(presenter.value("token")).to eq("••••••")
          end

          context "when there is no token at all" do
            let(:data) { { "name" => "Ada" } }

            it "shows nothing rather than masking an absent value" do
              expect(presenter.value("token")).to be_nil
            end
          end
        end
      end
    end
  end
end
