# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Vocdoni
      module AdminForms
        describe CensusFileSettingsForm do
          subject(:form) { described_class.new(election:) }

          let(:settings) do
            {
              "columns" => [{ "header" => "Name", "field" => "name" }],
              "fields" => %w(name email),
              "file" => { "name" => "people.csv", "rows" => 3, "imported_at" => "2026-01-01T00:00:00Z" },
              "identifiers" => %w(name)
            }
          end

          context "when the persisted census is a file census" do
            let(:election) { create(:election, census_manifest: "token_csv", census_settings: settings) }

            it "echoes back the columns, fields, file and identifiers" do
              expect(form.census_settings).to eq(settings)
            end
          end

          context "when there is no election" do
            let(:election) { nil }

            it "returns nothing" do
              expect(form.census_settings).to eq({})
            end
          end

          context "when the election is switching away from a file census" do
            let(:election) { create(:election, :with_internal_users_census) }

            before { election.census_manifest = "token_csv" }

            it "still reflects the persisted (not yet saved) census type" do
              expect(election.census_manifest_was).to eq("internal_users")
              expect(form.census_settings).to eq({})
            end
          end

          context "when the persisted census is a different type" do
            let(:election) { create(:election, :with_internal_users_census) }

            it "returns nothing" do
              expect(form.census_settings).to eq({})
            end
          end
        end
      end
    end
  end
end
