# frozen_string_literal: true

require "csv"

module Decidim
  module Elections
    module Vocdoni
      module AdminForms
        # The file itself, posted straight from the drop zone on the Census
        # tab: a plain multipart upload, not Decidim's upload modal.
        #
        # Reuses the legacy importer's upload rules and messages (CSV only,
        # a friendlier answer for spreadsheets, a size ceiling), which is why
        # it mimics `census_import`. Only checks the file can be read here;
        # what its columns mean is answered on the card, once it has been read.
        class CensusFileUploadForm < Decidim::Form
          include Decidim::HasUploadValidations
          include Decidim::ProcessesFileLocally

          mimic :census_import

          attribute :file, Decidim::Attributes::Blob

          # See `Admin::CensusImportForm`: the conditions must take the record,
          # because the upload modal replays these validators.
          validates :file, presence: true
          validates_with Admin::CensusImportForm::CensusFileValidator,
                         Admin::CensusImportForm::CensusFileSizeValidator,
                         attributes: [:file],
                         if: ->(form) { form.file.present? }
          validate :readable, if: ->(form) { form.file.present? && form.errors[:file].empty? }

          # The file in storage, where the review that follows can find it
          # again by signed id.
          #
          # Created only when asked for, which is after the file has been
          # checked and read: a spreadsheet, an empty file or something that is
          # not a CSV at all is refused without ever being stored. The uploaded
          # tempfile is gone at the end of the request, so this is what makes
          # the file outlive it.
          def blob
            @blob ||=
              if file.is_a?(ActiveStorage::Blob)
                file
              else
                ActiveStorage::Blob.create_and_upload!(
                  io: file.tempfile.tap(&:rewind),
                  filename: file.original_filename,
                  content_type: file.content_type
                )
              end
          end

          private

          # Wherever the file is right now. A multipart upload is already a
          # local tempfile and can be read where it lies; only a blob has to be
          # fetched out of storage.
          def with_local_path(&)
            return process_file_locally(file, &) if file.is_a?(ActiveStorage::Blob)

            yield file.tempfile.path
          end

          def readable
            with_local_path do |path|
              reader = CensusCsv::Reader.new(path).load!
              errors.add(:file, :no_known_columns) if reader.column_count.zero? || reader.row_count.zero?
            end
          rescue CSV::MalformedCSVError
            errors.add(:file, :malformed)
          rescue CensusCsv::UnreadableFile
            errors.add(:file, :unreadable)
          end
        end
      end
    end
  end
end
