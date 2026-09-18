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
          # predicate answers "no", and the rules this form exists to enforce
          # are skipped exactly when they matter: on save.
          describe "built the way the controller builds it" do
            subject(:form) { described_class.from_params({ security: { enable_vocdoni: "1" } }, election:) }

            let(:election) { create(:election, census_manifest: "token_csv", census_settings: { "fields" => %w(name nationalId) }) }

            before { Decidim::Elections::Voter.create!(election:, data: { "name" => "Rosalind", "nationalId" => "1X" }) }

            it "sees the census through the context" do
              expect(form.file_census?).to be(true)
              expect(form.census_fields).to eq(%w(name nationalId))
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
            let(:identifiers) { %w(name surname) }
            let(:election) do
              create(:election, census_manifest: "token_csv",
                                census_settings: { "fields" => fields, "identifiers" => identifiers })
            end
            let(:enable_vocdoni) { false }
            let(:form) { described_class.new(election:, enable_vocdoni:) }

            describe "#identifiers" do
              it "reads the details chosen on the Census tab" do
                expect(form.identifiers).to eq(%w(name surname))
              end

              context "when the file no longer maps a column that was chosen" do
                let(:fields) { %w(name) }

                it "keeps only the ones the file still maps" do
                  expect(form.identifiers).to eq(%w(name))
                end
              end
            end

            describe "#identifier_labels" do
              it "labels every chosen detail" do
                expect(form.identifier_labels).to eq(%w(name surname).map { |field| CensusCsv::Fields.label(field) })
              end
            end

            describe "#secure_identifiers" do
              context "when some chosen details prove identity to the SaaS and some do not" do
                let(:identifiers) { %w(name email) }

                it "keeps only the ones usable as authFields" do
                  expect(form.secure_identifiers).to eq(%w(name))
                end
              end
            end

            describe "#secure_blocked_by_identifiers?" do
              context "when the list is identified only by the access code, which a secret vote cannot use" do
                let(:identifiers) { %w(token) }

                it "is true" do
                  expect(form.secure_blocked_by_identifiers?).to be(true)
                end
              end

              context "when at least one chosen detail can prove identity to the SaaS" do
                let(:identifiers) { %w(name email) }

                it "is false" do
                  expect(form.secure_blocked_by_identifiers?).to be(false)
                end
              end

              context "when the census is identified by email alone: usable as a two-factor code, not blocked" do
                let(:identifiers) { %w(email) }

                it "is false" do
                  expect(form.secure_blocked_by_identifiers?).to be(false)
                end
              end

              context "when no identifier has been chosen yet" do
                let(:identifiers) { [] }

                it "is false: nothing to refuse yet" do
                  expect(form.secure_blocked_by_identifiers?).to be(false)
                end
              end

              context "when it is not a file census" do
                let(:election) { create(:election, :with_internal_users_census) }

                it "is false: the question does not apply" do
                  expect(form.secure_blocked_by_identifiers?).to be(false)
                end
              end
            end

            # There used to be a `#refused_identifier_labels` here, naming the
            # details a secret vote would drop. Only an access code is ever in
            # that list, and only a list identified by nothing else is worth
            # saying anything about, so the page names it in a sentence and
            # `#secure_blocked_by_identifiers?` above is the whole rule.

            describe "#secure_available?" do
              let(:identifiers) { %w(name) }

              context "when the census holds people this platform can identify" do
                before { Decidim::Elections::Voter.create!(election:, data: { "name" => "Ada" }) }

                it "is true" do
                  expect(form.secure_available?).to be(true)
                end
              end

              # How many people a secret vote may hold belongs to the
              # organisation's plan with the secure voting service, which this
              # platform cannot read. It used to be guessed here and enforced
              # as fact, which refused lists the service would have accepted;
              # now the census is pushed and the service answers for itself.
              context "when the census is larger than the roster this platform would push in one go" do
                around do |example|
                  previous = ENV.fetch("VOCDONI_MAX_ROSTER", nil)
                  ENV["VOCDONI_MAX_ROSTER"] = "1"
                  example.run
                  ENV["VOCDONI_MAX_ROSTER"] = previous
                end

                before do
                  Decidim::Elections::Voter.create!(election:, data: { "name" => "Ada" })
                  Decidim::Elections::Voter.create!(election:, data: { "name" => "Grace" })
                end

                it "is still true: size is the voting service's answer to give, not this page's" do
                  expect(form.secure_available?).to be(true)
                end
              end

              context "when the list is identified only by the access code, which a secret vote cannot use" do
                let(:identifiers) { %w(token) }

                before { Decidim::Elections::Voter.create!(election:, data: { "token" => "A1B2C3" }) }

                it "is false even though the census is small" do
                  expect(form.secure_available?).to be(false)
                end
              end

              context "when the list is identified by email alone: usable via the one-time code" do
                let(:identifiers) { %w(email) }

                before { Decidim::Elections::Voter.create!(election:, data: { "email" => "ada@example.org" }) }

                it "is true: email is a secure identifier" do
                  expect(form.secure_available?).to be(true)
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

            describe "#code_required?" do
              context "when the census identifies people by that detail" do
                let(:identifiers) { %w(name email) }

                it "is required for the identifying detail" do
                  expect(form.code_required?("email")).to be(true)
                end

                it "is not required for a detail the census does not identify people by" do
                  expect(form.code_required?("phone")).to be(false)
                end
              end

              context "when it is not a file census" do
                let(:election) { create(:election, :with_internal_users_census) }

                it "is false: the question does not apply" do
                  expect(form.code_required?("email")).to be(false)
                end
              end
            end

            describe "#two_fa_fields" do
              context "when the census identifies people by email, without the admin ticking the email box" do
                let(:identifiers) { %w(name email) }
                let(:form) { described_class.new(election:, enable_vocdoni: true) }

                it "turns the email channel on anyway: the code is what proves the person" do
                  expect(form.two_fa_fields).to eq(%w(email))
                end
              end

              context "when the census does not identify by a contact detail and no box is ticked" do
                let(:identifiers) { %w(name) }
                let(:form) { described_class.new(election:, enable_vocdoni: true) }

                it "sends no code" do
                  expect(form.two_fa_fields).to eq([])
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
