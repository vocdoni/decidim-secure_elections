# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Vocdoni
      module AdminForms
        describe CensusIdentifiersForm do
          let(:fields) { %w(name surname email phone) }
          let(:election) { create(:election, census_manifest: "token_csv", census_settings: { "fields" => fields }) }

          describe ".from_model" do
            it "reads whatever is already chosen for the census" do
              election.update!(census_settings: election.census_settings.merge("identifiers" => %w(name email)))

              form = described_class.from_model(election)

              expect(form.identifiers).to eq(%w(name email))
            end

            it "starts from nothing chosen when the census has no identifiers yet" do
              form = described_class.from_model(election)

              expect(form.identifiers).to eq([])
            end

            it "keeps a stored choice that the list can still answer" do
              election.update!(census_settings: election.census_settings.merge("identifiers" => %w(name email)))

              expect(described_class.from_model(election).chosen_identifiers).to eq(%w(name email))
            end

            it "derives from the columns instead of coming up blank when nothing is stored" do
              expect(described_class.from_model(election).chosen_identifiers).to eq(["email"])
            end

            context "when the stored identifiers name a column the list no longer has" do
              # Stale data: the census was remapped after the choice was made,
              # so nationalId is not one of `fields` any more. Blindly keeping
              # it would leave the card pointing at a column that does not
              # exist, which is exactly what `stored & available_fields`
              # (empty here) is meant to prevent.
              before { election.update!(census_settings: election.census_settings.merge("identifiers" => %w(nationalId))) }

              it "derives from the columns the list actually has now" do
                expect(described_class.from_model(election).chosen_identifiers).to eq(["email"])
              end
            end
          end

          describe "#available_fields" do
            it "follows the columns the census was mapped to" do
              expect(described_class.new(election:).available_fields).to eq(fields)
            end

            context "when the list was imported by upstream's own importer, with no stored columns" do
              let(:election) { create(:election, census_manifest: "token_csv", census_settings: {}) }

              before { Decidim::Elections::Voter.create!(election:, data: { "name" => "Ada", "memberNumber" => "1" }) }

              it "falls back to whatever a voter's row carries" do
                expect(described_class.new(election:).available_fields).to match_array(%w(name memberNumber))
              end
            end
          end

          describe "validity" do
            subject(:form) { described_class.new(election:, identifiers:) }

            context "when a valid choice is made" do
              let(:identifiers) { %w(name surname) }

              it { is_expected.to be_valid }

              it "keeps only the columns the list actually has" do
                expect(form.chosen_identifiers).to eq(%w(name surname))
              end
            end

            context "when nothing is chosen" do
              # The hidden field ahead of the checkboxes is what actually
              # reaches the server when every box is unticked; a bare `[]`
              # instead means no answer was given at all, and that falls back
              # to the derived identifiers rather than failing validation.
              let(:identifiers) { [""] }

              it "is invalid" do
                expect(form).to be_invalid
                expect(form.errors.details[:identifiers]).to include(a_hash_including(error: :blank))
              end
            end

            context "when the admin asks for more details than the rule would have picked" do
              let(:identifiers) { %w(name surname email phone) }

              it "takes them: the number of details is the admin's to decide" do
                expect(form).to be_valid
                expect(form.chosen_identifiers).to eq(%w(name surname email phone))
              end
            end

            context "when a chosen field is not one the list has" do
              let(:identifiers) { %w(name token) }

              it "is invalid" do
                expect(form).to be_invalid
                expect(form.errors.details[:identifiers]).to include(a_hash_including(error: :unknown))
              end
            end

            context "when the chosen combination cannot tell two voters apart" do
              let(:fields) { %w(name) }
              let(:identifiers) { %w(name) }

              before do
                Decidim::Elections::Voter.create!(election:, data: { "name" => "Ada" })
                Decidim::Elections::Voter.create!(election:, data: { "name" => "ada" })
              end

              it "is invalid and says how many rows collide" do
                expect(form).to be_invalid
                expect(form.errors.details[:identifiers]).to include(a_hash_including(error: :not_unique, count: 2))
              end
            end
          end

          describe "#people_without" do
            it "counts, in the database, the voters with nothing in that column" do
              Decidim::Elections::Voter.create!(election:, data: { "name" => "Ada", "email" => "ada@example.org" })
              Decidim::Elections::Voter.create!(election:, data: { "name" => "Grace", "email" => "" })
              Decidim::Elections::Voter.create!(election:, data: { "name" => "Rosalind" })

              expect(described_class.new(election:).people_without("email")).to eq(2)
            end

            it "is zero when there is no election yet" do
              expect(described_class.new.people_without("email")).to eq(0)
            end
          end

          # Shared with CensusFileMappingForm via the ChoosesIdentifiers concern;
          # exercised here because this host needs no uploaded file to set up.
          describe "the identifiers checkboxes (ChoosesIdentifiers)" do
            describe "a blank entry from the hidden field" do
              subject(:form) do
                described_class.from_params({ census_identifiers: { identifiers: ["", "name", "surname"] } }, election:)
              end

              it "is dropped rather than treated as a choice" do
                expect(form.chosen_identifiers).to eq(%w(name surname))
              end

              it "does not make the form invalid" do
                expect(form).to be_valid
              end
            end

            describe "#usable_for_secure?" do
              it "accepts email and phone: the one-time code sent there proves the person" do
                expect(described_class.new(election:).usable_for_secure?("email")).to be(true)
                expect(described_class.new(election:).usable_for_secure?("phone")).to be(true)
              end

              it "refuses the access code: the secure voting service has nowhere to put it" do
                expect(described_class.new(election:).usable_for_secure?("token")).to be(false)
              end
            end

            describe "#sends_code?" do
              it "is true for email and phone" do
                expect(described_class.new(election:).sends_code?("email")).to be(true)
                expect(described_class.new(election:).sends_code?("phone")).to be(true)
              end

              it "is false for a detail the service checks directly, with no code involved" do
                expect(described_class.new(election:).sends_code?("name")).to be(false)
              end
            end
          end

          # The controller builds this form with `from_params(params, election:)`,
          # which puts the election in the form's *context*, not its attributes.
          # `#election` has to read both, or `identifiers_checkable?` answers
          # "no" and every rule above is silently skipped on save.
          describe "built the way the controller builds it" do
            subject(:form) { described_class.from_params({ census_identifiers: { identifiers: %w(name) } }, election:) }

            it "sees the election through the context" do
              expect(form.election).to eq(election)
            end

            it "still enforces the rules" do
              expect(form).to be_valid
            end

            context "with an empty choice" do
              # [""], not []: the hidden field is what a real unticked
              # submission sends, and it must still be checked against the
              # context election rather than silently deriving.
              subject(:form) { described_class.from_params({ census_identifiers: { identifiers: [""] } }, election:) }

              it "is still invalid: the context election is not lost" do
                expect(form).to be_invalid
                expect(form.errors[:identifiers]).to be_present
              end
            end
          end
        end
      end
    end
  end
end
