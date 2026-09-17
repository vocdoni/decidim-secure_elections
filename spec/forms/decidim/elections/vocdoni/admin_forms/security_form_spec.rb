# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Vocdoni
      module AdminForms
        describe SecurityForm do
          let(:election) { create(:election) }

          # The controller never passes the election as an attribute: it calls
          # `from_params(params, election:)`, which puts it in the context. A
          # form that only looks at its attributes finds nothing there, every
          # predicate answers "no", and the identifier rules below are skipped
          # exactly when they matter — on save.
          describe "built the way the controller builds it" do
            subject(:form) do
              described_class.from_params({ security: { enable_vocdoni: "1", identifiers: [] } }, election:)
            end

            let(:election) { create(:election, census_manifest: "token_csv", census_settings: { "fields" => %w(name nationalId) }) }

            before { Decidim::Elections::Voter.create!(election:, data: { "name" => "Rosalind", "nationalId" => "1X" }) }

            it "sees the census through the context" do
              expect(form.file_census?).to be(true)
              expect(form.census_fields).to eq(%w(name nationalId))
            end

            it "still refuses a file census with no identifiers chosen" do
              expect(form).not_to be_valid
              expect(form.errors[:identifiers]).to be_present
            end
          end

          describe ".from_model" do
            subject(:form) { described_class.from_model(election) }

            context "when the election has not opted in" do
              it "shows a simple vote" do
                expect(form.enable_vocdoni).to be(false)
                expect(form.choice).to eq("simple")
                expect(form.level).to eq("basic")
              end
            end

            context "when the election opted in with both codes" do
              before do
                Vocdoni::Process.create!(election:, state: "pending",
                                         metadata: { "settings" => { "twofa_fields" => %w(email phone) } })
              end

              it "shows a secret vote with both codes" do
                expect(form.enable_vocdoni).to be(true)
                expect(form.choice).to eq("secure")
                expect(form.email).to be(true)
                expect(form.sms).to be(true)
                expect(form.level).to eq("strongest")
              end
            end

            context "when the election opted in without a code" do
              before { Vocdoni::Process.create!(election:, state: "pending") }

              it "shows a secret vote without a code" do
                expect(form.choice).to eq("secure")
                expect(form.two_fa_fields).to eq([])
                expect(form.level).to eq("strong")
              end
            end
          end

          describe "from the submitted page" do
            subject(:form) { described_class.from_params(security: params) }

            context "when the secret vote is chosen with the email code" do
              let(:params) { { enable_vocdoni: "true", email: "1" } }

              it "reads the radio and the checkbox" do
                expect(form.enable_vocdoni).to be(true)
                expect(form.two_fa_fields).to eq(%w(email))
              end
            end

            context "when the simple vote is chosen" do
              # The one-time code fieldset is disabled, so its boxes are not sent.
              let(:params) { { enable_vocdoni: "false" } }

              it "sends no code" do
                expect(form.enable_vocdoni).to be(false)
                expect(form.two_fa_fields).to eq([])
                expect(form.level).to eq("basic")
              end
            end

            context "when only the SMS code is chosen" do
              let(:params) { { enable_vocdoni: "true", email: "0", sms: "1" } }

              it "sends the phone code" do
                expect(form.two_fa_fields).to eq(%w(phone))
                expect(form.level).to eq("strongest")
              end
            end

            context "when both codes are chosen" do
              let(:params) { { enable_vocdoni: "true", email: "1", sms: "1" } }

              it "lets the voter pick" do
                expect(form.two_fa_fields).to eq(%w(email phone))
              end
            end
          end

          describe "for a file census" do
            let(:fields) { %w(name surname email token) }
            let(:election) { create(:election, census_manifest: "token_csv", census_settings: { "fields" => fields }) }
            let(:enable_vocdoni) { false }
            let(:identifiers) { [] }
            let(:form) { described_class.new(election:, enable_vocdoni:, identifiers:) }

            describe "#identifier_options" do
              it "follows the file's own mapped columns, in file order" do
                expect(form.identifier_options).to eq(%w(name surname email token))
              end

              context "when the file was not mapped to any identifying column" do
                let(:fields) { %w(weight) }

                it "is empty" do
                  expect(form.identifier_options).to eq([])
                end
              end
            end

            describe "#allowed_identifiers" do
              context "when it is a simple vote" do
                let(:enable_vocdoni) { false }

                it "allows every mapped column, including token and email" do
                  expect(form.allowed_identifiers).to include("token", "email")
                end
              end

              context "when it is a secure vote" do
                let(:enable_vocdoni) { true }

                it "refuses token and email, which the SaaS cannot use as auth fields" do
                  expect(form.allowed_identifiers).not_to include("token", "email")
                  expect(form.allowed_identifiers).to include("name", "surname")
                end
              end
            end

            context "when a secure vote picks token and email as identifiers" do
              let(:enable_vocdoni) { true }
              let(:identifiers) { %w(email token) }

              it "is invalid: neither can prove identity to the SaaS" do
                expect(form).to be_invalid
                expect(form.errors[:identifiers].to_sentence).to match(/can't be used for a secret, verifiable vote/i)
              end
            end

            context "when no identifier is chosen" do
              let(:identifiers) { [] }

              it "is invalid: at least one is required" do
                expect(form).to be_invalid
                expect(form.errors[:identifiers]).to be_present
              end
            end

            context "when more than the maximum number of identifiers is chosen" do
              let(:identifiers) { %w(name surname email token) }

              it "is invalid: at most 3 are accepted" do
                expect(form).to be_invalid
                expect(form.errors[:identifiers].to_sentence).to match(/at most 3/i)
              end
            end

            context "when two people in the list share the same identifier, case and spacing aside" do
              let(:identifiers) { %w(name) }

              before do
                Decidim::Elections::Voter.create!(election:, data: { "name" => "Ada" })
                Decidim::Elections::Voter.create!(election:, data: { "name" => "ada" })
              end

              it "is invalid: they could not be told apart" do
                expect(form).to be_invalid
                expect(form.errors[:identifiers].to_sentence).to match(/can't be told apart/i)
              end
            end

            describe "#weak_identifiers?" do
              context "with only guessable details and no one-time code" do
                let(:identifiers) { %w(name) }

                it "is true" do
                  expect(form.weak_identifiers?).to be(true)
                end
              end

              context "with a detail that is not guessable" do
                let(:identifiers) { %w(email) }

                it "is false" do
                  expect(form.weak_identifiers?).to be(false)
                end
              end

              context "with only guessable details but a one-time code enabled" do
                let(:enable_vocdoni) { true }
                let(:identifiers) { %w(name) }
                let(:form) { described_class.new(election:, enable_vocdoni:, identifiers:, email: true) }

                it "is false: the code makes up for it" do
                  expect(form.weak_identifiers?).to be(false)
                end
              end
            end

            describe "#email_code_available?" do
              context "when the file has no email column" do
                let(:fields) { %w(name surname) }

                it "is false" do
                  expect(form.email_code_available?).to be(false)
                end
              end

              context "when the file has an email column" do
                let(:fields) { %w(name email) }

                it "is true" do
                  expect(form.email_code_available?).to be(true)
                end
              end

              it "is dropped from two_fa_fields when unavailable" do
                election.update!(census_settings: { "fields" => %w(name surname) })
                form = described_class.new(election:, enable_vocdoni: true, email: true)

                expect(form.two_fa_fields).to eq([])
              end
            end

            describe "#sms_code_available?" do
              context "when the file has no phone column" do
                it "is false" do
                  expect(form.sms_code_available?).to be(false)
                end
              end

              context "when the file has a phone column" do
                let(:fields) { %w(name phone) }

                it "is true" do
                  expect(form.sms_code_available?).to be(true)
                end
              end
            end
          end

          describe "for a registered (internal users) census" do
            let(:election) { create(:election, :with_internal_users_census) }
            let(:form) { described_class.new(election:, enable_vocdoni: true) }

            it "has no SMS code available: Decidim keeps no phone number for them" do
              expect(form.sms_code_available?).to be(false)
            end

            it "always has the email code available: they always have an email address" do
              expect(form.email_code_available?).to be(true)
            end
          end

          describe ".from_model for a file census" do
            let(:election) do
              create(:election, census_manifest: "token_csv",
                                census_settings: { "fields" => %w(name surname), "identifiers" => %w(name) })
            end

            it "reads the chosen identifiers from the census settings" do
              form = described_class.from_model(election)

              expect(form.identifiers).to eq(%w(name))
            end
          end
        end
      end
    end
  end
end
