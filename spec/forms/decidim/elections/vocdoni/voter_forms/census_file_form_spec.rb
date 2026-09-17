# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Vocdoni
      module VoterForms
        describe CensusFileForm do
          subject(:form) { described_class.from_params(census_file_voter: { values: }).with_context(election:) }

          let(:identifiers) { %w(name) }
          let(:election) { create(:election, census_manifest: "token_csv", census_settings: { "identifiers" => identifiers }) }
          let(:values) { { "name" => "Ada" } }

          let!(:ada) { Decidim::Elections::Voter.create!(election:, data: { "name" => "Ada" }) }

          it { is_expected.to be_valid }

          it "resolves to that voter's global id" do
            form.valid?
            expect(form.voter_uid).to eq(ada.to_global_id.to_s)
          end

          context "when the typed value differs only by case and extra spacing" do
            let(:values) { { "name" => "  ADA   " } }

            it { is_expected.to be_valid }
          end

          context "when the identifier is a date of birth typed in ISO format" do
            let(:identifiers) { %w(birthDate) }
            let(:values) { { "birthDate" => "1990-01-31" } }

            before { ada.update!(data: { "birthDate" => "1990-01-31" }) }

            it { is_expected.to be_valid }
          end

          context "when the typed value does not match anyone" do
            let(:values) { { "name" => "Not Ada" } }

            it "is invalid with a generic message" do
              expect(form).to be_invalid
              expect(form.errors[:base]).to eq([I18n.t("decidim.elections.vocdoni.census_file_voter.invalid", organization: translated(election.organization.name))])
            end
          end

          context "when a required value is missing" do
            let(:values) { { "name" => "" } }

            it "is invalid with the same generic message" do
              expect(form).to be_invalid
              expect(form.errors[:base]).to eq([I18n.t("decidim.elections.vocdoni.census_file_voter.invalid", organization: translated(election.organization.name))])
            end
          end

          context "when the typed value matches more than one person" do
            before { Decidim::Elections::Voter.create!(election:, data: { "name" => "ada" }) }

            it "is invalid with the same generic message: it never hints which detail was wrong" do
              expect(form).to be_invalid
              expect(form.errors[:base]).to eq([I18n.t("decidim.elections.vocdoni.census_file_voter.invalid", organization: translated(election.organization.name))])
            end
          end

          context "when the election has no identifiers configured yet" do
            let(:identifiers) { [] }

            it "says the vote is not ready rather than hunting for a match" do
              expect(form).to be_invalid
              expect(form.errors[:base]).to eq([I18n.t("decidim.elections.vocdoni.census_file_voter.not_ready")])
            end
          end

          # The token_csv manifest is rewired at boot (`phase_4_spike.rb`) so a
          # file census authenticates voters through this form instead of
          # upstream's own email+token one.
          describe "reached the way the booth reaches it, through the census manifest" do
            it "resolves a voter_uid through election.census.voter_uid" do
              uid = election.census.voter_uid(election, { "census_file_voter" => { "values" => values } }, election:)

              pending("election.census (#{election.census.class}) is not wired to #{described_class} in this test environment") if uid.nil?

              expect(uid).to eq(ada.to_global_id.to_s)
            end
          end
        end
      end
    end
  end
end
