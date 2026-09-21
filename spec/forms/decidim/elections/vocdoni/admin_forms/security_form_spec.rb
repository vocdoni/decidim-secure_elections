# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Vocdoni
      module AdminForms
        describe SecurityForm do
          let(:election) { create(:election) }

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

          describe "#auth_fields" do
            context "when the fieldset is disabled (simple vote)" do
              subject(:form) { described_class.from_params(security: { enable_vocdoni: "false", auth_fields: [""] }) }

              it "collapses to the default" do
                expect(form.auth_fields).to eq(%w(memberNumber))
              end
            end

            context "when the admin picks two fields" do
              subject(:form) { described_class.from_params(security: { enable_vocdoni: "true", auth_fields: ["", "nationalId", "memberNumber"] }) }

              it "returns the allowlisted picks, sorted" do
                expect(form.auth_fields).to eq(%w(memberNumber nationalId))
              end

              it "is valid" do
                expect(form).to be_valid
              end
            end

            context "when the admin unchecks every box" do
              subject(:form) { described_class.from_params(security: { enable_vocdoni: "true", auth_fields: [""] }) }

              it "is invalid" do
                expect(form).not_to be_valid
                expect(form.errors[:auth_fields]).to be_present
              end
            end

            context "when the params contain a field the SaaS rejects" do
              subject(:form) { described_class.from_params(security: { enable_vocdoni: "true", auth_fields: ["", "memberNumber", "email"] }) }

              it "is invalid" do
                expect(form).not_to be_valid
                expect(form.errors[:auth_fields]).to be_present
              end
            end

            context "when reading a sidecar that predates this feature" do
              subject(:form) { described_class.from_model(election) }

              before { Vocdoni::Process.create!(election:, state: "pending") }

              it "defaults to memberNumber" do
                expect(form.auth_fields).to eq(%w(memberNumber))
              end
            end

            context "when reading a sidecar that stored auth_fields" do
              subject(:form) { described_class.from_model(election) }

              before do
                Vocdoni::Process.create!(election:, state: "pending",
                                         metadata: { "settings" => { "auth_fields" => %w(nationalId memberNumber) } })
              end

              it "reads them back, sorted" do
                expect(form.auth_fields).to eq(%w(memberNumber nationalId))
              end
            end
          end
        end
      end
    end
  end
end
