# frozen_string_literal: true

require "csv"

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Uploading a census as a spreadsheet.
      #
      # The file is read locally and never leaves Decidim: members only reach
      # Vocdoni when the election is published, from a background job.
      class CensusImportForm < Decidim::Form
        include Decidim::HasUploadValidations
        include Decidim::ProcessesFileLocally

        mimic :census_import

        # The only extension this importer reads. Deliberately one entry: the
        # importer parses CSV and nothing else, so an allowlist that admits
        # anything more is a promise the code does not keep.
        ALLOWED_EXTENSIONS = %w(csv).freeze

        # Files an admin will genuinely try to upload and that are worth a
        # better answer than "not a CSV" — every one of them is a real census
        # that is one "Save as" away from being importable. XLSX would need
        # `roo` as a runtime dependency, which this module deliberately does
        # not carry (see {Decidim::Elections::Vocdoni::CensusCsv}).
        SPREADSHEET_EXTENSIONS = %w(xlsx xlsm xlsb xls xlt xltx ods fods numbers).freeze

        # Ceiling for a single upload, sized against
        # {Decidim::Elections::Vocdoni::CensusCsv::MAX_ROWS}.
        #
        # The arithmetic. A row with every one of the eight member fields
        # filled in is about 120 bytes — roughly `Ada,Lovelace,
        # ada@example.org,+34600000000,000123,12345678Z,1990-01-01,1` plus its
        # separators and line ending, rounded up for long names. At the 20,000
        # rows the importer will read that is ~2.4 MB, and a UTF-16 export of
        # the same census is ~4.8 MB. 25 MB is five times the largest census
        # this module will accept in full, which is headroom for a file with
        # extra columns, generous quoting or a very long free-text field, and
        # still nowhere near the size at which reading the file is the
        # problem.
        #
        # Because the whole file is read into memory before `MAX_ROWS` can cap
        # anything, without this an accidental drag of a 2 GB file is a memory
        # event rather than an error message.
        #
        # This is *this importer's* ceiling, not the deployment's. Decidim also
        # caps every direct upload at `upload_maximum_file_size` (10 MB out of
        # the box), enforced when the blob is created and therefore earlier
        # than anything here; on a default installation that is the binding
        # limit and this one is the backstop. The two are reconciled where it
        # matters — the panel quotes whichever is smaller, so the guidance is
        # true of the deployment the admin is actually using.
        MAX_FILE_SIZE = 25.megabytes

        # What this importer will really accept here and now: its own ceiling,
        # or the organization's upload limit if that is tighter.
        #
        # @param organization [Decidim::Organization, nil]
        # @return [Integer] bytes.
        def self.effective_max_file_size(organization)
          return MAX_FILE_SIZE if organization.blank?

          [MAX_FILE_SIZE, Decidim.organization_settings(organization).upload_maximum_file_size.to_i].min
        end

        # What the module will even try to read, checked by extension.
        #
        # It replaces a `file_content_type` allowlist, which was wrong in both
        # directions. The types a browser reports for a CSV are unreliable
        # enough that the allowlist had to include `text/plain`,
        # `application/vnd.ms-excel` and `application/octet-stream` — and
        # Decidim renders a rejection by expanding every allowed type into
        # every extension MiniMime knows for it. So an admin who attached an
        # `.xlsx` was told, in a paragraph of two hundred characters, that
        # `.dll`, `.so`, `.class` and `.dylib` were welcome and their
        # spreadsheet was not. Both halves of that were true, and both were
        # wrong.
        #
        # An extension check says one thing and says it plainly. A binary
        # renamed to `.csv` still gets through — nothing but reading the file
        # can catch that — and is refused a moment later by
        # {Decidim::Elections::Vocdoni::CensusCsv::Source} as unreadable, which is the
        # answer it deserves rather than a 500.
        #
        # An `EachValidator` rather than a `validate` block, because that is
        # the only kind `PassthruValidator` replays: the upload modal has to
        # be able to refuse a spreadsheet at the moment it is attached, not
        # only once the form is submitted.
        class CensusFileValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value)
            extension = extension_of(value)
            return if ALLOWED_EXTENSIONS.include?(extension)

            record.errors.add(attribute, SPREADSHEET_EXTENSIONS.include?(extension) ? :spreadsheet : :not_csv)
          end

          private

          # `ActiveStorage::Blob` answers `filename`; an
          # `ActionDispatch::Http::UploadedFile`, which is what arrives when a
          # form is posted without the modal, answers `original_filename`.
          def extension_of(value)
            filename = value.try(:filename) || value.try(:original_filename)
            File.extname(filename.to_s).delete_prefix(".").downcase
          end
        end

        # How much file this importer will take, checked before anything reads
        # it.
        #
        # An `EachValidator` for the same reason as the one above: it is the
        # only kind `PassthruValidator` replays, so the modal can say no at the
        # moment the file is attached rather than after the admin has waited
        # for an upload and a submit.
        #
        # It also has to run *before* `#parseable`, which is what downloads the
        # file and reads it whole. That ordering is the point of the check: the
        # limit exists so that the read never happens, not so that it is
        # reported afterwards.
        class CensusFileSizeValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value)
            bytes = size_of(value)
            return if bytes.nil? || bytes <= MAX_FILE_SIZE

            record.errors.add(
              attribute,
              :too_large,
              size: human_size(bytes),
              limit: human_size(MAX_FILE_SIZE)
            )
          end

          private

          # `ActiveStorage::Blob` answers `byte_size`; an
          # `ActionDispatch::Http::UploadedFile` answers `size`.
          def size_of(value)
            value.try(:byte_size) || value.try(:size)
          end

          def human_size(bytes)
            ActiveSupport::NumberHelper.number_to_human_size(bytes)
          end
        end

        attribute :file, Decidim::Attributes::Blob

        # Replace the current census instead of adding to it. Off by default:
        # losing a census to a stray second upload is not recoverable from the
        # admin UI.
        attribute :replace, Boolean, default: false

        # The conditions take the record explicitly. They have to: the upload
        # modal validates a file before the form is ever submitted, and
        # `Decidim::UploadValidationForm` does that by replaying *these*
        # validators against a throwaway record through `PassthruValidator`,
        # which calls every `:if` with `condition.call(record)`. A zero-arity
        # lambda raises `ArgumentError` there, `POST /upload_validations`
        # answers 500, the modal never lets the file be attached, and the
        # eventual submit arrives with no file at all.
        validates :file, presence: true
        validates :file, census_file: true, census_file_size: true, if: ->(form) { form.file.present? }

        # Only once the file has passed the cheap checks. `#parseable`
        # downloads the file and reads it whole, so running it on something
        # already known to be a 2 GB `.dll` would defeat both of the validators
        # above — and would pile a second, vaguer sentence on top of the one
        # that already named the problem.
        validate :parseable, if: ->(form) { form.file.present? && form.errors[:file].empty? }

        def election
          @election ||= context[:election]
        end

        private

        # Reject a file that is not a census *before* a command starts writing
        # rows, so a malformed upload cannot leave half a census behind.
        #
        # Note that this is a plain `validate`, not an `EachValidator`, so
        # `PassthruValidator` skips it and the upload modal never runs it: the
        # modal only ever sees the validators above. That is deliberate —
        # parsing a census inside a keystroke-latency validation endpoint is
        # not something to do twice — but it does mean the format and size
        # checks have to stand on their own, which is why they are
        # `EachValidator`s.
        def parseable
          process_file_locally(file) do |path|
            importer = Vocdoni::CensusCsv::Importer.new(election, path)
            errors.add(:file, :no_known_columns) if importer.mapping.compact.empty?
          end
        rescue CSV::MalformedCSVError
          errors.add(:file, :malformed)
        rescue Vocdoni::CensusCsv::UnreadableFile
          errors.add(:file, :unreadable)
        end
      end
    end
  end
end
end
