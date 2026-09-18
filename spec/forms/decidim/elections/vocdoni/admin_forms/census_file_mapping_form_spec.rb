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
          let(:identifiers) { %w(name) }
          let(:attributes) { { census_file: { blob: blob.signed_id, columns:, identifiers: } } }

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

          describe "#guessed_indexes and #unknown_indexes" do
            it "separates the headings the importer recognised by itself from the rest" do
              # Nombre, Apellidos and Correo are recognised Spanish headers;
              # Ciudad is not one of the fields this census understands.
              expect(form.guessed_indexes).to eq([0, 1, 2])
              expect(form.unknown_indexes).to eq([3])
            end
          end

          describe "#kept_pairs" do
            it "pairs every kept heading with the label of the detail it was mapped to" do
              expect(form.kept_pairs).to eq(
                [
                  ["Nombre", CensusCsv::Fields.label("name")],
                  ["Apellidos", CensusCsv::Fields.label("surname")],
                  ["Correo", CensusCsv::Fields.label("email")]
                ]
              )
            end
          end

          describe "#dropped_headers" do
            it "lists the headings of the columns that were not kept" do
              expect(form.dropped_headers).to eq(%w(Ciudad))
            end
          end

          describe "#people_without" do
            let(:content) do
              <<~CSV
                Nombre,Apellidos,Correo,Ciudad
                Ada,Lovelace,ada@example.org,London
                Grace,Hopper,,Paris
              CSV
            end

            it "counts the rows about to be imported that have nothing in that column" do
              expect(form.people_without("email")).to eq(1)
            end

            context "when the file cannot be checked yet (a blob error, an unmapped column)" do
              let(:attributes) { { census_file: { columns: } } }

              it "is zero rather than raising" do
                expect(form.people_without("email")).to eq(0)
              end
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

          describe "the details voters type to be found on the list" do
            context "when the form was built without any identifiers param" do
              let(:attributes) { { census_file: { blob: blob.signed_id, columns: } } }

              # The wizard's last step never asks any more: the card just
              # shows what the mapped columns already imply.
              it "derives them from the mapped columns" do
                expect(form.chosen_identifiers).to eq(["email"])
              end

              it "is valid on that derived choice alone" do
                expect(form).to be_valid
              end
            end

            context "when the admin picks a field other than the one that would be derived" do
              let(:identifiers) { %w(surname) }

              it "respects the submitted choice instead of deriving one" do
                expect(form.chosen_identifiers).to eq(%w(surname))
              end
            end

            context "when every box is unticked" do
              # The hidden field ahead of the checkboxes is what a real
              # submission sends when nothing is ticked; it must count as the
              # admin's answer, not be read as "no answer" and fall back to
              # the derived identifiers.
              let(:identifiers) { [""] }

              it "is invalid" do
                expect(form).to be_invalid
                expect(form.errors.details[:identifiers]).to include(a_hash_including(error: :blank))
              end
            end

            context "when the chosen field is a column that was not kept" do
              # The email column is dropped: only name and surname remain.
              let(:columns) { { "0" => "name", "1" => "surname", "2" => "", "3" => "" } }
              let(:identifiers) { %w(email) }

              it "is invalid" do
                expect(form).to be_invalid
                expect(form.errors.details[:identifiers]).to include(a_hash_including(error: :unknown))
              end
            end

            context "when two of the rows about to be imported cannot be told apart by the chosen details" do
              let(:content) do
                <<~CSV
                  Nombre,Apellidos,Correo,Ciudad
                  Rosalind,Franklin,rosalind@example.org,London
                  Rosalind,Franklin,rosalind2@example.org,Paris
                CSV
              end
              let(:identifiers) { %w(name surname) }

              it "is invalid and says how many rows collide" do
                expect(form).to be_invalid
                expect(form.errors.details[:identifiers]).to include(a_hash_including(error: :not_unique, count: 2))
              end
            end

            context "when the file has a row to fix" do
              # The duplicate check runs against the rows that would actually
              # be imported; a row-level error (a bad email) is not one of
              # them, so it is not counted as a collision.
              let(:content) do
                <<~CSV
                  Nombre,Apellidos,Correo,Ciudad
                  Ada,Lovelace,not-an-email,London
                  Ada,Lovelace,ada2@example.org,Paris
                CSV
              end
              let(:identifiers) { %w(name surname) }

              it "is otherwise valid: the identifiers do not collide" do
                expect(form).to be_valid
              end
            end
          end
        end
      end
    end
  end
end
