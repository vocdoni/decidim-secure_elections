# frozen_string_literal: true

require "csv"

module Decidim
  module Elections
    module Vocdoni
      module AdminForms
        # Step 2 of the census file wizard: what each column means.
        #
        # `columns` maps a column position ("0", "1", …) to a field of
        # {CensusCsv::Fields::TARGETS}, or "" to leave the column out. The
        # uploaded file travels as a signed blob id between steps.
        class CensusFileMappingForm < Decidim::Form
          include Decidim::ProcessesFileLocally

          mimic :census_file

          attribute :blob, String
          attribute :columns, { String => String }

          validate :file_present
          validate :targets_known, :targets_unique, :something_kept, if: -> { reader.present? }

          # Pre-selects a sensible target for every column, never the same one
          # twice (the first column that looks like an email wins).
          def self.suggested_columns(reader)
            taken = Set.new
            reader.headers.each_with_index.to_h do |header, index|
              field = CensusCsv::Fields.suggest(header)
              [index.to_s, field && taken.add?(field) ? field : ""]
            end
          end

          def file
            @file ||= ActiveStorage::Blob.find_signed(blob.to_s) if blob.present?
          end

          # The parsed file, read once.
          def reader
            return @reader if defined?(@reader)

            @reader = nil
            return @reader if file.blank?

            process_file_locally(file) { |path| @reader = CensusCsv::Reader.new(path).load! }
            @reader
          rescue CSV::MalformedCSVError, CensusCsv::UnreadableFile
            @reader = nil
          end

          def headers
            reader&.headers || []
          end

          # One entry per column: the chosen field or nil.
          def mapping
            headers.each_index.map { |index| columns.to_h[index.to_s].presence }
          end

          def selected(index)
            columns.to_h[index.to_s].to_s
          end

          def fields
            mapping.compact
          end

          def settings_columns
            headers.each_with_index.map { |header, index| { "header" => header, "field" => mapping[index] } }
          end

          def lacks_identity?
            !fields.intersect?(CensusCsv::Fields::IDENTITY)
          end

          private

          def file_present
            errors.add(:blob, :missing) if file.blank? || reader.blank?
          end

          def targets_known
            unknown = fields - CensusCsv::Fields::TARGETS
            errors.add(:columns, :unknown) if unknown.any?
          end

          def targets_unique
            repeated = fields.tally.select { |_field, count| count > 1 }.keys
            return if repeated.empty?

            errors.add(:columns, :repeated, fields: repeated.map { |field| CensusCsv::Fields.label(field) }.to_sentence)
          end

          def something_kept
            errors.add(:columns, :empty) if fields.empty?
          end
        end
      end
    end
  end
end
