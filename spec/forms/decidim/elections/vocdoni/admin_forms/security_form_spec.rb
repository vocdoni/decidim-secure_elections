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
        end
      end
    end
  end
end
