# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    module Admin
      describe CensusImportForm do
        subject(:form) { described_class.from_params(attributes).with_context(context) }

        let(:organization) { create(:organization) }
        let(:election) { create(:vocdoni_election, census_auth_fields: ["memberNumber"]) }
        let(:context) { { current_organization: organization, election: } }

        let(:content) do
          <<~CSV
            name,surname,memberNumber
            Ada,Lovelace,000123
          CSV
        end

        let(:filename) { "census.csv" }
        let(:content_type) { "text/csv" }

        let(:blob) do
          ActiveStorage::Blob.create_and_upload!(
            io: StringIO.new(content),
            filename:,
            content_type:
          )
        end

        let(:attributes) { { census_import: { file: blob.signed_id, replace: "0" } } }

        it { is_expected.to be_valid }

        context "when no file was chosen" do
          let(:attributes) { { census_import: { replace: "0" } } }

          it { is_expected.to be_invalid }
        end

        context "when the file has no column this census knows" do
          let(:content) do
            <<~CSV
              colour,shape
              red,round
            CSV
          end

          it "is refused before a command starts writing rows" do
            expect(form).to be_invalid
            expect(form.errors.full_messages.to_sentence).to match(/no column this census recognises/i)
          end
        end

        context "when the file is not a CSV at all" do
          let(:content) { "name,surname\n\"unterminated,quote\n" }

          it "is refused rather than raised" do
            expect(form).to be_invalid
            expect(form.errors.full_messages.to_sentence).to match(/could not be read as a CSV/i)
          end
        end

        # An Excel "Unicode Text" export renamed to `.csv`, a `.dll`, a JPEG —
        # anything whose bytes are not text. This used to reach
        # `File#readline` and raise `ArgumentError: invalid byte sequence in
        # UTF-8` with nothing to rescue it: a blank 500 on the census page,
        # with no flash and no way back.
        context "when the file is not text" do
          let(:content) { "\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR".b }

          it "is an error message rather than an exception" do
            expect { form.valid? }.not_to raise_error
            expect(form).to be_invalid
            expect(form.errors.full_messages.to_sentence).to match(/could not be read as text/i)
          end

          it "tells the admin what to save instead" do
            form.valid?
            expect(form.errors.full_messages.to_sentence).to include("CSV UTF-8")
          end
        end

        # The file allowlist. It used to be a `file_content_type` list wide
        # enough to admit `.dll`, `.so` and `.class` — which the importer then
        # crashed on — while refusing the one format every admin will actually
        # try, and it said so by reciting sixty extensions.
        describe "which files are accepted at all" do
          context "when the file is a spreadsheet" do
            let(:filename) { "census.xlsx" }
            let(:content_type) { "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }

            it "says to save it as CSV rather than reciting extensions" do
              expect(form).to be_invalid
              expect(form.errors.full_messages.to_sentence).to match(/is a spreadsheet/i)
              expect(form.errors.full_messages.to_sentence).to match(/Save as/i)
              expect(form.errors.full_messages.to_sentence).not_to match(/dll|dylib|\bso\b/)
            end
          end

          context "when the file is a binary" do
            let(:filename) { "census.dll" }
            let(:content_type) { "application/octet-stream" }

            it "is refused" do
              expect(form).to be_invalid
              expect(form.errors.full_messages.to_sentence).to match(/is not a CSV file/i)
            end
          end

          context "when the extension is upper case" do
            let(:filename) { "CENSUS.CSV" }

            it { is_expected.to be_valid }
          end
        end

        # The file is read whole into memory before `MAX_ROWS` can cap
        # anything, so without a ceiling an accidental drag of a very large
        # file is a memory event rather than an error message. The limit is
        # stubbed down rather than a 25 MB fixture being uploaded: what is
        # under test is the check and its wording, not `number_to_human_size`.
        describe "how much file is accepted" do
          before { stub_const("#{described_class}::MAX_FILE_SIZE", 8) }

          it "refuses it, and says by how much and what to do" do
            expect(form).to be_invalid

            message = form.errors.full_messages.to_sentence
            expect(message).to match(/up to 8 Bytes can be imported at once/i)
            expect(message).to match(/split it/i)
          end

          # The point of the ceiling is that the read never happens. If
          # `#parseable` still ran, the oversized file would be downloaded and
          # walked anyway — and the admin would get a second, vaguer sentence
          # on top of the one that named the problem.
          it "does not go on to read the file" do
            expect(form).not_to receive(:process_file_locally)

            form.valid?
          end

          context "when the file is within the limit" do
            before { stub_const("#{described_class}::MAX_FILE_SIZE", 25.megabytes) }

            it { is_expected.to be_valid }
          end
        end

        # What the panel is allowed to promise. Decidim caps every direct
        # upload at the organization's `upload_maximum_file_size`, enforced
        # when the blob is created and so before anything here runs — quoting
        # this module's own 25 MB on a platform configured for 10 would be a
        # promise the deployment does not keep.
        describe ".effective_max_file_size" do
          it "is this importer's own ceiling when nothing tighter applies" do
            expect(described_class.effective_max_file_size(nil)).to eq(described_class::MAX_FILE_SIZE)
          end

          it "gives way to the organization's upload limit when that is smaller" do
            expect(described_class.effective_max_file_size(organization))
              .to eq(Decidim.organization_settings(organization).upload_maximum_file_size.to_i)
          end

          it "does not rise above its own ceiling when the organization allows more" do
            organization.update!(file_upload_settings: organization.file_upload_settings.deep_merge("maximum_file_size" => { "default" => 500.0 }))
            # `Decidim.organization_settings` caches per organization id, so
            # the new value is invisible until the registry is told about it.
            Decidim::OrganizationSettings.reload(organization)

            expect(described_class.effective_max_file_size(organization)).to eq(described_class::MAX_FILE_SIZE)
          end
        end

        # The upload field is a modal that validates the file before the form is
        # ever submitted, by replaying *this* class's `:file` validators against
        # a throwaway record through `Decidim::PassthruValidator`. That replay
        # calls every `:if` condition as `condition.call(record)`, so a
        # zero-arity lambda raises `ArgumentError` there and
        # `POST /upload_validations` answers 500. The visible consequence is not
        # an error message: the modal simply never attaches the file, the form
        # is submitted with no file at all, and the import reports that nothing
        # could be read from a file it never received.
        describe "the upload modal's pre-flight validation" do
          subject(:upload_validation) do
            Decidim::UploadValidationForm.from_params(
              resource_class: described_class.name,
              property: "file",
              blob: blob.signed_id,
              form_class: described_class.name
            ).with_context(current_organization: organization)
          end

          it "can replay the file validators without blowing up" do
            expect { upload_validation.valid? }.not_to raise_error
          end

          it "accepts a CSV" do
            expect(upload_validation).to be_valid
          end

          # `PassthruValidator` only replays `EachValidator`s, which is why the
          # format check is one: an `.xlsx` has to be refused at the moment it
          # is attached, not after the form has been submitted.
          context "when a spreadsheet is attached" do
            let(:filename) { "census.xlsx" }
            let(:content_type) { "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }

            it "is refused in the modal, with the reason" do
              expect(upload_validation).to be_invalid
              expect(upload_validation.errors.full_messages.to_sentence).to match(/is a spreadsheet/i)
            end
          end

          # An admin should learn a file is too big at the moment they attach
          # it, not after waiting for a submit. Same reason the format check is
          # an `EachValidator`: nothing else is replayed here.
          context "when the file is too large" do
            before { stub_const("#{described_class}::MAX_FILE_SIZE", 8) }

            it "is refused in the modal, with the limit named" do
              expect(upload_validation).to be_invalid
              expect(upload_validation.errors.full_messages.to_sentence).to match(/up to 8 Bytes can be imported at once/i)
            end
          end
        end
      end
    end
  end
end
end
