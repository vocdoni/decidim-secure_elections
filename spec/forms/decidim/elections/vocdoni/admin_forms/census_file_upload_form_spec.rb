# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      module AdminForms
        describe CensusFileUploadForm do
          subject(:form) { described_class.from_params(attributes) }

          let(:content) do
            <<~CSV
              name,surname
              Ada,Lovelace
            CSV
          end

          let(:filename) { "people.csv" }
          let(:content_type) { "text/csv" }

          let(:blob) do
            ActiveStorage::Blob.create_and_upload!(
              io: StringIO.new(content),
              filename:,
              content_type:
            )
          end

          let(:attributes) { { census_import: { file: blob.signed_id } } }

          it { is_expected.to be_valid }

          context "when no file was chosen" do
            let(:attributes) { { census_import: {} } }

            it "is invalid" do
              expect(form).to be_invalid
              expect(form.errors[:file]).to be_present
            end
          end

          context "when the file is a spreadsheet" do
            let(:filename) { "people.xlsx" }
            let(:content_type) { "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }

            it "is refused before it is even read" do
              expect(form).to be_invalid
              expect(form.errors.full_messages.to_sentence).to match(/is a spreadsheet/i)
            end
          end

          context "when the file is not text" do
            let(:content) { "\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR".b }

            it "is refused as unreadable rather than raising" do
              expect { form.valid? }.not_to raise_error
              expect(form).to be_invalid
              expect(form.errors.full_messages.to_sentence).to match(/could not be read as text/i)
            end
          end

          context "when the file has only a header row" do
            let(:content) { "name,surname\n" }

            it "is refused: there is nobody in it" do
              expect(form).to be_invalid
              expect(form.errors.full_messages.to_sentence).to match(/no column this census recognises/i)
            end
          end
        end
      end
    end
  end
end
