# frozen_string_literal: true

require "csv"

module Decidim
  module Elections
    module Vocdoni
      module AdminForms
        # Step 1 of the census file wizard: the file.
        #
        # Reuses the legacy importer's upload rules and messages (CSV only,
        # a friendlier answer for spreadsheets, a size ceiling), which is why
        # it mimics `census_import`. Only checks the file can be read here; the
        # columns are looked at in step 2.
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

          private

          def readable
            process_file_locally(file) do |path|
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
