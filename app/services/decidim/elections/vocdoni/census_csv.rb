# frozen_string_literal: true

require "csv"

module Decidim
  module Elections
    module Vocdoni
    # Reading and writing the census as a spreadsheet.
    #
    # Two halves, mirroring the Vocdoni app's import dialog
    # (`Memberbase/Members/MembersCsvManager.tsx`):
    #
    # * {Template} — "Download Import Template": tick the columns you want, get
    #   a CSV with exactly those headers and one example row.
    # * {Importer} — read a file back, validating **per row**. A file with
    #   three bad rows out of two hundred imports one hundred and ninety-seven
    #   and says precisely what was wrong with the other three. Failing the
    #   whole upload because one birth date was typed as `31/02/1990` is how
    #   admins end up editing CSVs in the dark.
    #
    # ASSUMPTION: only CSV is accepted. XLSX/ODS would need a spreadsheet gem
    # (`roo`) as a new runtime dependency; the app supports them, we do not.
    module CensusCsv
      # Practical ceiling for a single upload. Well past any realistic Decidim
      # census, low enough that a malicious 200 MB file cannot be walked row by
      # row inside a request.
      MAX_ROWS = 20_000

      # The file is not text this importer can decode. Raised by {Source} and
      # turned into a normal validation error by
      # {Decidim::Elections::Vocdoni::Admin::CensusImportForm}; it must never reach a
      # controller, because the alternative is the blank 500 an
      # `ArgumentError: invalid byte sequence in UTF-8` used to produce.
      class UnreadableFile < StandardError; end

      # Decoding the uploaded file into a UTF-8 String.
      #
      # An admin's "CSV" is whatever their spreadsheet wrote, and the thing it
      # most often is not is UTF-8. Two cases are read rather than refused,
      # because in both the admin did save a spreadsheet as a text file and
      # has no way of knowing the difference:
      #
      # * **UTF-16** — Excel's "Unicode Text" export, and its "CSV UTF-16"
      #   variants. Always carries a byte-order mark, so it is detected
      #   exactly rather than guessed at.
      # * **Windows-1252** — what Excel's plain "CSV (Comma delimited)" writes
      #   on a Western Windows install. It has no mark, so it is the fallback
      #   for a file that is text but is not valid UTF-8.
      #
      # Everything else is refused with {UnreadableFile}. That covers the
      # `.dll` and the `.png` renamed to `.csv`, and — importantly — the
      # `.xlsx`, which is a ZIP: decoding one as Windows-1252 would not fail,
      # it would succeed and produce a column called `PK`, so the guess has to
      # stop before it gets that far.
      #
      # Nothing here is reachable from a happy-path UTF-8 file: that is one
      # `valid_encoding?` check and no conversion at all.
      class Source
        # Byte-order marks, longest first. `\xFF\xFE` is also the first half
        # of the UTF-32LE mark, so a two-byte match must never be tried before
        # a four-byte one.
        BOMS = [
          ["\xFF\xFE\x00\x00", Encoding::UTF_32LE],
          ["\x00\x00\xFE\xFF", Encoding::UTF_32BE],
          ["\xEF\xBB\xBF", Encoding::UTF_8],
          ["\xFF\xFE", Encoding::UTF_16LE],
          ["\xFE\xFF", Encoding::UTF_16BE]
        ].map { |mark, encoding| [mark.b, encoding] }.freeze

        # Windows-1252 rather than ISO-8859-1: it is what Excel actually
        # emits, it decodes every byte ISO-8859-1 does in the same way, and it
        # leaves five bytes undefined — which is five more chances for a
        # binary file to be caught rather than mangled.
        FALLBACK_ENCODING = Encoding::WINDOWS_1252

        # @param path [String] a local path to the uploaded file.
        def initialize(path)
          @path = path
        end

        attr_reader :path

        # @return [String] the file as UTF-8, byte-order mark removed.
        # @raise [UnreadableFile] when it is not text this importer can read.
        def text
          @text ||= decode
        end

        private

        def decode
          raw = File.binread(path)
          mark, encoding = BOMS.find { |candidate, _| raw.start_with?(candidate) }
          body = mark ? raw.byteslice(mark.bytesize..) || "".b : raw

          # A mark is a statement of fact, and UTF-16 and UTF-32 are full of
          # NUL bytes by construction, so the binary check below must not see
          # them.
          return convert(body, encoding) if encoding

          # Before the UTF-8 test, not after it. An `.xlsx` is a ZIP, and a
          # ZIP's first bytes — `PK\x03\x04\x14\x00…` — are every one of them
          # valid UTF-8, so a file that is unmistakably binary would otherwise
          # sail through and be imported as a census with a column called
          # "PK". Text does not contain NUL; this is the whole test.
          raise UnreadableFile if binary?(body)

          utf8 = body.dup.force_encoding(Encoding::UTF_8)
          return utf8 if utf8.valid_encoding?

          convert(body, FALLBACK_ENCODING)
        rescue SystemCallError, IOError
          raise UnreadableFile
        end

        def convert(body, encoding)
          converted = body.dup.force_encoding(encoding).encode(Encoding::UTF_8)
          raise UnreadableFile unless converted.valid_encoding?

          converted
        rescue EncodingError
          raise UnreadableFile
        end

        # No text encoding left at this point uses a NUL byte — the ones that
        # do (UTF-16, UTF-32) were identified by their mark and converted
        # already — and every binary format is full of them. Cheap, and it
        # refuses a ZIP, a `.dll` or an image before either the UTF-8 test or
        # the Windows-1252 fallback can turn it into plausible-looking
        # nonsense.
        def binary?(body)
          body.include?("\x00".b)
        end
      end

      # Emits the import template for a chosen set of fields.
      class Template
        # One filled-in row, so it is obvious what shape each column expects —
        # `birthDate` in particular is ISO 8601 and nothing else.
        EXAMPLES = {
          "name" => "Ada",
          "surname" => "Lovelace",
          "email" => "ada@example.org",
          "phone" => "+34600000000",
          "memberNumber" => "000123",
          "nationalId" => "12345678Z",
          "birthDate" => "1990-01-01",
          "weight" => "1"
        }.freeze

        # @param fields [Array<String>] upstream field ids, in display order.
        def initialize(fields)
          @fields = Array(fields) & Vocdoni::CensusMember::FIELDS
        end

        attr_reader :fields

        def any?
          fields.any?
        end

        # Headers are the canonical field ids rather than the localized labels
        # the Vocdoni app uses. They round-trip unambiguously: a template
        # downloaded in Catalan can be re-imported by an English admin. The
        # importer accepts the labels too, for files written by hand.
        def headers
          fields
        end

        def filename
          "census-template.csv"
        end

        def to_csv
          CSV.generate do |csv|
            csv << headers
            csv << fields.map { |field| EXAMPLES.fetch(field, "") }
          end
        end
      end

      # Outcome of an import: what went in, what did not and why, and — when
      # the admin asked to replace the census — how many people that cost
      # them. `removed` is filled in by
      # {Decidim::Elections::Vocdoni::Admin::ImportCensusMembers}, which is the only
      # thing that deletes anything; the importer itself never does.
      # `skipped_examples` counts the template's own example rows, which are
      # recognised and left out rather than imported as people.
      Result = Struct.new(:imported, :failed_rows, :total, :removed, :skipped_examples, keyword_init: true) do
        def imported_count = imported.to_i

        def failed_count = Array(failed_rows).size

        def removed_count = removed.to_i

        def skipped_examples_count = skipped_examples.to_i

        def any_failures? = failed_count.positive?

        def any_imported? = imported_count.positive?

        def any_removed? = removed_count.positive?

        def any_skipped_examples? = skipped_examples_count.positive?
      end

      # One rejected row, reported back with its line number so the admin can
      # find it in their own file.
      FailedRow = Struct.new(:number, :cells, :messages, keyword_init: true) do
        def summary = Array(messages).join(", ")
      end

      # Reads a CSV into census members.
      class Importer
        # @param election [Decidim::Elections::Vocdoni::Election]
        # @param path [String] a local path to the uploaded file.
        def initialize(election, path)
          @election = election
          @path = path
        end

        attr_reader :election, :path

        # @return [Decidim::Elections::Vocdoni::CensusCsv::Result]
        # @raise [CSV::MalformedCSVError] when the file is not a CSV at all.
        # @raise [UnreadableFile] when the file is not text this importer can
        #   decode. Both are turned into a form error before a command ever
        #   calls this.
        def import!
          imported = 0
          failed = []
          total = 0
          skipped_examples = 0

          rows.each do |row, number|
            if example_row?(row)
              skipped_examples += 1
              next
            end

            total += 1
            member, problems = build(row)
            problems += duplicate_problems(member)

            if problems.empty? && member.save
              remember(member)
              imported += 1
            else
              messages = problems + member.errors.full_messages
              failed << FailedRow.new(number:, cells: row.to_h.compact_blank, messages:)
            end
          end

          Result.new(imported:, failed_rows: failed, total:, skipped_examples:)
        ensure
          # A rejected row is never saved, but `CensusMember.new(election:)`
          # still writes it into the inverse association's target, where
          # `election.census_members` keeps returning it for the rest of the
          # request. That is what made a failed import re-render the census
          # page with the refused people listed in it, counted, and marked
          # incomplete — rows that exist nowhere but in memory.
          election.census_members.reset
        end

        # Header row mapped onto field ids, `nil` for columns we do not know.
        # Exposed so a caller can warn about a column that will be ignored.
        def mapping
          @mapping ||= headers.map { |header| self.class.field_for(header) }
        end

        def unknown_headers
          headers.each_with_index.reject { |_header, index| mapping[index] }.map(&:first)
        end

        # Matches a header against the field ids, the local column names and
        # the localized labels, ignoring case, spaces and punctuation. That
        # covers `memberNumber`, `member_number`, `Member number` and
        # `Número de socio` without asking the admin to care.
        #
        # @param header [String]
        # @return [String, nil] the field id.
        def self.field_for(header)
          key = normalize(header)
          return nil if key.blank?

          aliases.fetch(key, nil)
        end

        def self.normalize(value)
          value.to_s.unicode_normalize(:nfkd).gsub(/[^\p{Alnum}]/, "").downcase
        end

        # Rebuilt per locale, because the labels are translated.
        def self.aliases
          Vocdoni::CensusMember::FIELDS.each_with_object({}) do |field, map|
            map[normalize(field)] = field
            map[normalize(Vocdoni::CensusMember.attribute_for(field))] = field
            map[normalize(Vocdoni::CensusMember.field_label(field))] = field
          end
        end

        private

        # The file, decoded once. Everything below reads this String rather
        # than the path: `CSV.read` and `File#readline` both raise a bare
        # `ArgumentError: invalid byte sequence in UTF-8` on anything that is
        # not valid UTF-8, from deep inside the standard library and with
        # nothing in the message an admin could act on. {Source} answers that
        # question once, up front, with an exception that has an answer
        # attached to it.
        def source
          @source ||= Source.new(path).text
        end

        def table
          @table ||= CSV.parse(source, headers: true, col_sep: separator)
        end

        def headers
          @headers ||= Array(table.headers).map(&:to_s)
        end

        # Spreadsheet exports from several European locales use `;`. Guessing
        # from the header line is cheap and beats an unreadable "1 column"
        # error.
        def separator
          @separator ||= begin
            line = source.each_line.first.to_s
            line.count(";") > line.count(",") ? ";" : ","
          end
        end

        def rows
          return enum_for(:rows) unless block_given?

          table.each_with_index do |row, index|
            break if index >= MAX_ROWS

            # A trailing blank line is not a failed row, it is nothing.
            next if row.to_h.values.all?(&:blank?)

            yield row, index + 2 # +1 for zero-based, +1 for the header line
          end
        end

        # The template's own example row, which must never become a voter.
        #
        # {Template} ships one filled row so that the shape of each column is
        # obvious — `birthDate` is ISO 8601 and nothing else — and that is
        # worth keeping. What is not is what happened when the template was
        # uploaded unedited: Ada Lovelace joined the census, status "Ready",
        # indistinguishable from a real person. On an election that
        # authenticates on the member number alone that is not merely untidy:
        # `000123` is printed in a file anybody can download, so the example
        # row is a public credential and her ballot is anybody's to cast.
        #
        # It is skipped rather than refused, and the skip is reported by the
        # caller: a row that disappears without a word is how the next admin
        # concludes the importer is eating people.
        #
        # The match is deliberately strict. Every column this importer
        # recognises has to carry exactly the example's value, so a real
        # person cannot be dropped by coincidence, and a row the admin has
        # edited at all — one digit of the member number — is an ordinary row
        # again. Columns we do not recognise are not compared: they are not
        # imported either, so they cannot make the row a person.
        def example_row?(row)
          compared = mapping.each_with_index.filter_map do |field, index|
            next if field.blank?

            [Template::EXAMPLES[field], row[index].to_s.strip]
          end

          compared.any? && compared.all? { |expected, actual| expected == actual }
        end

        # @return [Array(Decidim::Elections::Vocdoni::CensusMember, Array<String>)] the
        #   member and everything wrong with the row that the model itself
        #   cannot see.
        def build(row)
          # Built standalone rather than through the association: a rejected
          # row must not linger in `election.census_members`.
          member = Vocdoni::CensusMember.new(election:)
          problems = []

          mapping.each_with_index do |field, index|
            next if field.blank?

            value, error = cast(field, row[index])
            problems << error if error
            member.write_field(field, value)
          end

          # A row missing what the census authenticates on is imported as a
          # person who cannot vote. Rejecting it here, naming the column, is
          # the difference between fixing a spreadsheet and discovering the
          # problem as an upstream `40037` once the ballot is being published
          # (ARCHITECTURE §4c-bis).
          problems += member.missing_fields.map do |field|
            I18n.t("decidim.elections.vocdoni.admin.census.import.missing_required",
                   field: Vocdoni::CensusMember.field_label(field))
          end

          [member, problems]
        end

        # Dates and weights come out of a spreadsheet as strings. A value that
        # cannot be read is reported rather than cast to `nil`: silently
        # dropping a birth date is exactly the sort of thing that only surfaces
        # once the election is already on chain.
        def cast(field, value)
          return [nil, nil] if value.blank?

          case field
          when "birthDate"
            [Date.iso8601(value.to_s.strip), nil]
          when "weight"
            number = Integer(value.to_s.strip, exception: false)
            number ? [number, nil] : [nil, invalid_value_message(field, value)]
          else
            [value.to_s.strip, nil]
          end
        # Date::Error is a subclass of ArgumentError, so the one rescue covers both.
        rescue ArgumentError
          [nil, invalid_value_message(field, value)]
        end

        def invalid_value_message(field, value)
          I18n.t("decidim.elections.vocdoni.admin.census.import.invalid_value",
                 field: Vocdoni::CensusMember.field_label(field),
                 value: value.to_s.truncate(40))
        end

        # Fields this election resolves a voter by. Two people sharing one of
        # them is either a double vote or an authentication that lands on the
        # wrong row, which is why the members table refuses it outright
        # (`CensusMembersForm#no_duplicates`). A spreadsheet must not be the
        # way around that rule: uploading the same file twice used to double
        # the census silently.
        def unique_fields
          @unique_fields ||= election.census_fields & Vocdoni::CensusMember::EDITABLE_FIELDS
        end

        # What is already spoken for, per field: the census as it stands, plus
        # everything this run has imported so far. Loaded once — a query per
        # row on a twenty-thousand-row file is not an option.
        #
        # Queried through a bare relation rather than through
        # `election.census_members`: the association may already be loaded, and
        # building a member for the current row puts it in that association's
        # target before it is saved, which would have every row collide with
        # itself.
        def taken
          @taken ||= unique_fields.index_with do |field|
            attribute = Vocdoni::CensusMember.attribute_for(field)
            Vocdoni::CensusMember.where(election:).pluck(attribute).filter_map { |value| normalize_value(value) }.to_set
          end
        end

        def duplicate_problems(member)
          unique_fields.filter_map do |field|
            value = normalize_value(member.value_for(field))
            next if value.blank? || taken[field].exclude?(value)

            I18n.t("decidim.elections.vocdoni.admin.census.import.duplicate",
                   field: Vocdoni::CensusMember.field_label(field),
                   value: member.value_for(field).to_s.truncate(40))
          end
        end

        def remember(member)
          unique_fields.each do |field|
            value = normalize_value(member.value_for(field))
            taken[field] << value if value.present?
          end
        end

        def normalize_value(value)
          value.to_s.strip.downcase.presence
        end
      end
    end
  end
end
end
