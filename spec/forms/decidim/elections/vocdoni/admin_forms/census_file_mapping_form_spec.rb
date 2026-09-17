# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      module AdminForms
        describe CensusFileMappingForm do
          subject(:form) { described_class.from_params(attributes) }

          let(:content) do
            <<~CSV
              Nombre,Apellidos,Correo,Ciudad
              Ada,Lovelace,ada@example.org,London
            CSV
          end

          let(:blob) do
            ActiveStorage::Blob.create_and_upload!(
              io: StringIO.new(content),
              filename: "people.csv",
              content_type: "text/csv"
            )
          end

          let(:columns) { { "0" => "name", "1" => "surname", "2" => "email", "3" => "" } }
          let(:attributes) { { census_file: { blob: blob.signed_id, columns: } } }

          it { is_expected.to be_valid }

          describe ".suggested_columns" do
            subject(:suggested) { described_class.suggested_columns(reader) }

            let(:reader) { CensusCsv::Reader.new(tempfile_path(content)).load! }

            def tempfile_path(raw)
              Tempfile.new(["census", ".csv"]).tap do |file|
                file.write(raw)
                file.rewind
              end.path
            end

            it "recognises the Spanish headers" do
              expect(suggested).to eq("0" => "name", "1" => "surname", "2" => "email", "3" => "")
            end

            context "when the same target would be suggested twice" do
              let(:content) do
                <<~CSV
                  Correo,Email
                  a@example.org,b@example.org
                CSV
              end

              it "keeps the target for the first column only" do
                expect(suggested).to eq("0" => "email", "1" => "")
              end
            end

            context "when a header is not recognised" do
              let(:content) do
                <<~CSV
                  Nombre,Ciudad
                  Ada,London
                CSV
              end

              it "suggests nothing for it" do
                expect(suggested).to eq("0" => "name", "1" => "")
              end
            end
          end

          context "when a target is chosen for two columns" do
            let(:columns) { { "0" => "name", "1" => "name", "2" => "email", "3" => "" } }

            it "is invalid" do
              expect(form).to be_invalid
              expect(form.errors[:columns]).to be_present
            end
          end

          context "when nothing is kept" do
            let(:columns) { { "0" => "", "1" => "", "2" => "", "3" => "" } }

            it "is invalid" do
              expect(form).to be_invalid
              expect(form.errors[:columns]).to be_present
            end
          end

          context "when a column is mapped to a target this census does not know" do
            let(:columns) { { "0" => "name", "1" => "not_a_real_target", "2" => "email", "3" => "" } }

            it "is invalid" do
              expect(form).to be_invalid
              expect(form.errors[:columns]).to be_present
            end
          end

          context "when the blob id is missing" do
            let(:attributes) { { census_file: { columns: } } }

            it "is invalid" do
              expect(form).to be_invalid
              expect(form.errors[:blob]).to be_present
            end
          end

          context "when the blob id does not resolve to a real blob" do
            let(:attributes) { { census_file: { blob: "not-a-real-signed-id", columns: } } }

            it "is invalid" do
              expect(form).to be_invalid
              expect(form.errors[:blob]).to be_present
            end
          end

          describe "#fields" do
            it "lists the targets actually kept, in column order" do
              expect(form.fields).to eq(%w(name surname email))
            end
          end

          describe "#settings_columns" do
            it "pairs every header with its chosen field, including the dropped ones" do
              expect(form.settings_columns).to eq(
                [
                  { "header" => "Nombre", "field" => "name" },
                  { "header" => "Apellidos", "field" => "surname" },
                  { "header" => "Correo", "field" => "email" },
                  { "header" => "Ciudad", "field" => nil }
                ]
              )
            end
          end

          describe "#lacks_identity?" do
            it "is false once an identity field is kept" do
              expect(form.lacks_identity?).to be(false)
            end

            context "when no identity field was kept" do
              let(:columns) { { "0" => "name", "1" => "surname", "2" => "", "3" => "" } }

              it "is true" do
                expect(form.lacks_identity?).to be(true)
              end
            end
          end
        end
      end
    end
  end
end
