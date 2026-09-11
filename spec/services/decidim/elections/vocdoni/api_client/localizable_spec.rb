# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    describe ApiClient::Localizable do
      subject(:localize) { described_class.localize(value) }

      let(:value) { nil }

      describe "plain values" do
        context "with a string" do
          let(:value) { "Board election" }

          it { is_expected.to eq("default" => "Board election") }
        end

        context "with a symbol" do
          let(:value) { :ongoing }

          it { is_expected.to eq("default" => "ongoing") }
        end

        context "with a number" do
          let(:value) { 42 }

          it { is_expected.to eq("default" => "42") }
        end

        context "with nil" do
          let(:value) { nil }

          it { is_expected.to be_nil }
        end

        context "with a blank string" do
          let(:value) { "   " }

          it { is_expected.to be_nil }
        end
      end

      describe "translated hashes" do
        context "with the organization default locale present" do
          let(:value) { { "en" => "Hi", "ca" => "Hola" } }

          it "promotes it to the default key and keeps every locale" do
            expect(localize).to eq("default" => "Hi", "en" => "Hi", "ca" => "Hola")
          end

          it "puts the default key first" do
            expect(localize.keys).to eq(%w(default en ca))
          end
        end

        context "with an explicit default locale" do
          let(:value) { { "en" => "Hi", "ca" => "Hola" } }

          it "uses that locale for the default key" do
            expect(described_class.localize(value, default_locale: "ca")).to eq(
              "default" => "Hola", "en" => "Hi", "ca" => "Hola"
            )
          end

          it "accepts a symbol" do
            expect(described_class.localize(value, default_locale: :ca)["default"]).to eq("Hola")
          end

          it "falls back to the Decidim default locale when that locale is missing" do
            expect(described_class.localize(value, default_locale: "de")["default"]).to eq("Hi")
          end
        end

        context "with symbol keys" do
          let(:value) { { en: "Hi", ca: "Hola" } }

          it "stringifies them" do
            expect(localize).to eq("default" => "Hi", "en" => "Hi", "ca" => "Hola")
          end
        end

        context "when the hash already carries a default" do
          let(:value) { { "default" => "Fallback", "en" => "Hi" } }

          it "never overwrites it" do
            expect(described_class.localize(value, default_locale: "en")).to eq(
              "default" => "Fallback", "en" => "Hi"
            )
          end
        end

        context "when no known default locale is present" do
          let(:value) { { "ca" => "Hola", "es" => "Hola" } }

          it "falls back to the first non-blank translation" do
            expect(localize).to eq("default" => "Hola", "ca" => "Hola", "es" => "Hola")
          end
        end

        context "when the default locale translation is blank" do
          let(:value) { { "en" => "", "ca" => "Hola" } }

          it "drops the blank entry and falls back" do
            expect(localize).to eq("default" => "Hola", "ca" => "Hola")
          end
        end

        context "when every translation is blank" do
          let(:value) { { "en" => "", "ca" => nil } }

          it { is_expected.to be_nil }
        end

        context "with an empty hash" do
          let(:value) { {} }

          it { is_expected.to be_nil }
        end

        context "with machine translations" do
          let(:value) { { "en" => "Hi", "machine_translations" => { "ca" => "Hola" } } }

          it "flattens them into plain locale keys" do
            expect(localize).to eq("default" => "Hi", "en" => "Hi", "ca" => "Hola")
          end

          it "never lets them shadow a real translation" do
            value["machine_translations"]["en"] = "Machine hi"

            expect(localize["en"]).to eq("Hi")
          end
        end

        context "with a machine translation for the default locale only" do
          let(:value) { { "ca" => "Hola", "machine_translations" => { "en" => "Hi" } } }

          it "uses it for the default key" do
            expect(localize).to eq("default" => "Hi", "ca" => "Hola", "en" => "Hi")
          end
        end

        context "with non-text values" do
          let(:value) { { "en" => "Hi", "ca" => { "nested" => "no" }, "es" => %w(no) } }

          it "drops them instead of stringifying garbage" do
            expect(localize).to eq("default" => "Hi", "en" => "Hi")
          end
        end

        context "with a HashWithIndifferentAccess" do
          let(:value) { { "en" => "Hi" }.with_indifferent_access }

          it "works the same" do
            expect(localize).to eq("default" => "Hi", "en" => "Hi")
          end
        end
      end

      describe "locale fallbacks" do
        let(:value) { { "en" => "Hi", "ca" => "Hola" } }

        it "uses the I18n default locale when Decidim has none" do
          allow(Decidim).to receive(:default_locale).and_return(nil)
          allow(I18n).to receive(:default_locale).and_return(:ca)

          expect(localize["default"]).to eq("Hola")
        end
      end

      describe "input safety" do
        let(:value) { { "en" => "Hi" }.freeze }

        it "never mutates the input" do
          expect(localize).to eq("default" => "Hi", "en" => "Hi")
          expect(value).to eq("en" => "Hi")
        end
      end

      describe "the shape the API demands" do
        let(:value) { { en: "Hi", ca: "Hola" } }

        it "is a flat map of strings to strings" do
          expect(localize.keys).to all(be_a(String))
          expect(localize.values).to all(be_a(String))
          expect(localize.to_json).to eq('{"default":"Hi","en":"Hi","ca":"Hola"}')
        end
      end
    end
  end
end
end
