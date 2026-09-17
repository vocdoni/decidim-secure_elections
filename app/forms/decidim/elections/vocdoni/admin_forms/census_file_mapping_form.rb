# frozen_string_literal: true

require "csv"

module Decidim
  module Elections
    module Vocdoni
      module AdminForms
        # Step 2 of the census file wizard: what each column means, and which
        # of those details a voter types to be found on the list.
        #
        # `columns` maps a column position ("0", "1", …) to a field of
        # {CensusCsv::Fields::TARGETS}, or "" to leave the column out. The
        # uploaded file travels as a signed blob id between steps.
        #
        # The identifiers are asked here rather than on the Security tab
        # because the columns are already on screen: it is the same decision as
        # matching them, one question later.
        class CensusFileMappingForm < Decidim::Form
          include Decidim::ProcessesFileLocally
          include ChoosesIdentifiers

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

          alias available_fields fields

          # The rows this import would create, mapped and cleaned once: the
          # identifier check needs them here, and {Admin::ImportCensusFile}
          # reuses the same outcome instead of parsing the file twice.
          def outcome
            @outcome ||= CensusCsv::RowMapper.new(reader, mapping).call
          end

          def identifiers_checkable?
            reader.present? && errors[:blob].empty? && errors[:columns].empty?
          end

          # Columns whose heading the importer recognised by itself. Only the
          # others are worth an admin's attention: re-asking about the ones it
          # already knows turns a moment's confirmation into nine decisions,
          # all looking equally certain.
          def guessed?(index)
            CensusCsv::Fields.suggest(headers[index]).present?
          end

          def guessed_indexes
            headers.each_index.select { |index| guessed?(index) }
          end

          def unknown_indexes
            headers.each_index.reject { |index| guessed?(index) }
          end

          # Columns being kept, as "heading → detail" pairs, in file order.
          def kept_pairs
            headers.each_with_index.filter_map do |header, index|
              field = mapping[index]
              [header, CensusCsv::Fields.label(field)] if field
            end
          end

          def dropped_headers
            headers.each_with_index.filter_map { |header, index| header if mapping[index].nil? }
          end

          # How many of the people in this file have nothing in that column.
          # Asked about email and phone before the admin picks one as the way
          # people identify themselves, because those are the ones a list
          # tends to be missing.
          def people_without(field)
            return 0 unless identifiers_checkable?

            outcome.rows.count { |row| row[field].blank? }
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

          # Counted on the rows about to be imported: two people the chosen
          # details cannot tell apart would both be refused at sign-in, and
          # neither would know why.
          def identifier_duplicates(chosen)
            return 0 if chosen.empty? || outcome.failed? || outcome.rows.empty?

            outcome.rows
                   .group_by { |row| chosen.map { |field| CensusCsv::Fields.comparable(field, row[field]) } }
                   .sum { |_key, rows| rows.size > 1 ? rows.size : 0 }
          end
        end
      end
    end
  end
end
