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
          "weight" => "1",
          "token" => "A1B2C3"
        }.freeze

        # `token` is not a {Vocdoni::CensusMember} field — it exists only for
        # {CensusCsv::Fields}, the file-mapping layer introduced alongside
        # this — so it has to be allow-listed explicitly here rather than
        # inferred from the model, the way every other field is.
        ALLOWED_FIELDS = (Vocdoni::CensusMember::FIELDS + %w(token)).freeze

        # @param fields [Array<String>] upstream field ids, in display order.
        def initialize(fields)
          @fields = Array(fields) & ALLOWED_FIELDS
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

      # Human-facing metadata and per-cell cleaning for the fixed field
      # vocabulary a CSV column is mapped onto.
      #
      # Deliberately independent of {Vocdoni::CensusMember}: `token` exists
      # here and nowhere in the model, and this module has to work before a
      # single row has been turned into a member — it is what an admin-facing
      # "map your columns" screen is built on. {Importer}, by contrast, reads
      # straight into {Vocdoni::CensusMember} and is left exactly as it was.
      module Fields
        TARGETS = %w(memberNumber nationalId name surname birthDate email phone weight token).freeze

        # Vocdoni's memberbase needs at least one of these to identify a voter.
        IDENTITY = %w(memberNumber nationalId email phone).freeze

        # Usable as Vocdoni `authFields` — details a voter types and the
        # service checks against the member list.
        AUTH = %w(memberNumber nationalId name surname birthDate).freeze

        # Contact details. The service refuses these as `authFields` (verified
        # against saas-api-dev: `authFields: ["email"]` is a 400), but takes
        # them as `twoFaFields`, where the one-time code sent there is what
        # proves the person. So they identify a voter of a secret vote too —
        # by a different mechanism, which is why choosing one turns the code
        # on rather than being refused.
        TWO_FA = %w(email phone).freeze

        # Everything a voter of a secret, verifiable vote can be asked for,
        # one way or the other. Only an access code we hand out is left: the
        # service has nowhere to put it.
        SECURE_IDENTIFIERS = (AUTH + TWO_FA).freeze

        # Usable to sign in to a simple (non-Vocdoni) vote.
        SIMPLE_IDENTIFIERS = (TARGETS - %w(weight)).freeze

        # Guessable on their own, so not enough by themselves to identify a
        # voter with any confidence.
        WEAK = %w(name surname birthDate).freeze

        EXAMPLES = {
          "memberNumber" => "000123",
          "nationalId" => "12345678Z",
          "name" => "Ada",
          "surname" => "Lovelace",
          "birthDate" => "1990-01-31",
          "email" => "ada@example.org",
          "phone" => "+34600000000",
          "weight" => "1",
          "token" => "A1B2C3"
        }.freeze

        EXAMPLE_VALUES = EXAMPLES.values.freeze

        # Header aliases {Importer.field_for} cannot know about: either the
        # field (`token`) is not part of {Vocdoni::CensusMember} at all, or
        # the header an admin actually types (a Spanish or Catalan
        # abbreviation, a spreadsheet's own casing) is not the field's
        # translated label. Keys are normalised the same way as
        # {Importer.normalize}.
        EXTRA_ALIAS_WORDS = {
          "token" => %w(token code accesscode codigo codi pin password),
          "nationalId" => %w(dni nie nif passport pasaporte documento document idnumber nationalid),
          "name" => %w(nombre nom firstname givenname),
          "surname" => %w(apellidos apellido cognoms lastname familyname),
          "email" => %w(correo email mail correoelectronico correuelectronic),
          "phone" => %w(telefono telefon movil mobile phone),
          "birthDate" => %w(fechanacimiento datanaixement birthdate dob dateofbirth),
          "memberNumber" => %w(numerosocio nsocio socio membernumber member numsoci nosocio),
          "weight" => %w(peso pes weight votes)
        }.freeze

        # @param field [String]
        # @return [String] human label, e.g. "Member number".
        def self.label(field)
          I18n.t(field, scope: "decidim.elections.vocdoni.admin.census_file.fields", default: field.to_s)
        end

        # The same detail as it reads inside a sentence. The labels are
        # titles ("National ID number"), and downcasing one mid-sentence gives
        # "national id number", so the inline wording is written out.
        #
        # @param field [String]
        # @return [String]
        def self.in_sentence(field)
          I18n.t(field, scope: "decidim.elections.vocdoni.admin.census_file.fields_in_sentence", default: label(field).downcase)
        end

        # @param field [String]
        # @return [String] a one-line, non-technical explanation.
        def self.hint(field)
          I18n.t(field, scope: "decidim.elections.vocdoni.admin.census_file.field_hints", default: "")
        end

        # @param field [String]
        # @return [String, nil] a plausible example value, for templates and help text.
        def self.example(field)
          EXAMPLES[field.to_s]
        end

        # True for the filled-in example line the downloaded template carries.
        # That line must never become a real person: its member number and
        # access code are the same in every template this instance hands out,
        # so anyone could use them to vote.
        #
        # {RowMapper} decides authoritatively, on the mapped values, once the
        # admin has said what each column means. This answers the same
        # question from the raw cells, before that — so the matching step can
        # say up front that a file carries no real people, instead of
        # promising an import that then has nothing to import.
        #
        # @param cells [Array<String, nil>]
        def self.example_row?(cells)
          values = Array(cells).map { |cell| cell.to_s.strip }.reject(&:empty?)
          return false if values.empty?

          values.all? { |value| EXAMPLE_VALUES.include?(value) }
        end

        # Every target's own label, normalised once so a header that reads
        # exactly like a downloaded template's own column headers — "Member
        # number", "Access code" — round-trips even though those labels are
        # not part of {Vocdoni::CensusMember} at all, or differ from its
        # legacy ones (`weight`'s legacy label is "Voting power";
        # {.label}'s is "Voting weight").
        LABEL_ALIASES = TARGETS.index_by { |field| Importer.normalize(label(field)) }.freeze

        ALIASES = EXTRA_ALIAS_WORDS.each_with_object({}) do |(field, words), map|
          words.each { |word| map[Importer.normalize(word)] = field }
        end.merge(LABEL_ALIASES).freeze

        # Suggests a target for a CSV header: the field id, the local
        # attribute name and the legacy member label via
        # {Importer.field_for}, then this vocabulary's own labels and the
        # extra aliases above.
        #
        # @param header [String]
        # @return [String, nil] one of {TARGETS}, or nil to leave it unmapped.
        def self.suggest(header)
          field = Importer.field_for(header)
          return field if field.present? && TARGETS.include?(field)

          ALIASES[Importer.normalize(header)]
        end

        DATE_FORMATS = [
          [/\A(\d{4})-(\d{2})-(\d{2})\z/, :ymd],
          [%r{\A(\d{4})/(\d{2})/(\d{2})\z}, :ymd],
          [%r{\A(\d{2})/(\d{2})/(\d{4})\z}, :dmy],
          [/\A(\d{2})-(\d{2})-(\d{4})\z/, :dmy],
          [/\A(\d{2})\.(\d{2})\.(\d{4})\z/, :dmy]
        ].freeze

        # Cleans one cell for storage and for comparing what a voter types at
        # sign-in.
        #
        # @param field [String]
        # @param value [String, nil]
        # @return [Array(Object, nil), Array(nil, String)] `[value, nil]` on
        #   success, `[nil, error_message]` on failure. A blank cell is
        #   always `[nil, nil]`.
        def self.clean(field, value)
          cleaned = common_clean(value)
          return [nil, nil] if cleaned.nil?

          case field.to_s
          when "email"
            clean_email(cleaned)
          when "birthDate"
            clean_birth_date(cleaned)
          when "phone"
            clean_phone(cleaned)
          when "weight"
            clean_weight(cleaned)
          else
            [cleaned, nil]
          end
        end

        # @param field [String]
        # @param value [String, nil]
        # @return [Object, nil] what {.clean} would store, downcased when it
        #   is a String, so two spellings of the same value compare equal.
        def self.comparable(field, value)
          cleaned = clean(field, value).first
          cleaned.is_a?(String) ? cleaned.downcase : cleaned
        end

        # @return [String, nil] `nil` for a blank value, otherwise stripped,
        #   internal whitespace collapsed to one space, Unicode-normalised.
        def self.common_clean(value)
          return nil if value.nil?

          stripped = value.to_s.strip.gsub(/\s+/, " ")
          return nil if stripped.blank?

          stripped.unicode_normalize(:nfc)
        end

        def self.clean_email(value)
          downcased = value.downcase
          return [downcased, nil] if downcased.match?(URI::MailTo::EMAIL_REGEXP)

          [nil, row_error(:invalid_email, value)]
        end

        # Accepts `YYYY-MM-DD`, `YYYY/MM/DD`, `DD/MM/YYYY`, `DD-MM-YYYY` and
        # `DD.MM.YYYY` — day first, European, in every format except the ISO
        # one — and returns ISO `YYYY-MM-DD`. `31/02/1990` and the like are
        # rejected rather than silently rolled over to March.
        def self.clean_birth_date(value)
          DATE_FORMATS.each do |regex, order|
            match = regex.match(value)
            next unless match

            year, month, day = order == :ymd ? match.captures : match.captures.reverse
            begin
              return [Date.new(year.to_i, month.to_i, day.to_i).iso8601, nil]
            rescue ArgumentError
              # Date::Error is a subclass of ArgumentError, so this one
              # rescue covers both — same reasoning as Importer#cast.
              return [nil, row_error(:invalid_date, value)]
            end
          end

          [nil, row_error(:invalid_date, value)]
        end

        # Keeps a leading "+" and digits only; anything with fewer than 6
        # digits is not a phone number.
        def self.clean_phone(value)
          plus = value.start_with?("+") ? "+" : ""
          digits = value.delete("^0-9")
          return [nil, row_error(:invalid_phone, value)] if digits.length < 6

          ["#{plus}#{digits}", nil]
        end

        def self.clean_weight(value)
          return [value.to_i, nil] if value.match?(/\A[1-9]\d*\z/)

          [nil, row_error(:invalid_weight, value)]
        end

        def self.row_error(key, value)
          I18n.t(key, scope: "decidim.elections.vocdoni.admin.census_file.rows", value: value.to_s.truncate(40))
        end
      end

      # Picks what a voter types to be found on the list, from the columns the
      # list actually has.
      #
      # This used to be a question put to the admin. It is a question they have
      # no better information to answer than we do: the answer follows from the
      # columns, and getting it wrong is invisible until somebody cannot vote.
      # So it is decided here and shown as a sentence they can overrule.
      #
      # Pure, and deliberately so: the two callers count duplicates and blanks
      # very differently (one over rows it is about to import, one with a
      # GROUP BY over rows already imported), and neither belongs in a rule
      # that is really about which detail is the better question to ask.
      module Identifiers
        # Best first. Ahead of anything else, a detail that is unique to one
        # person by definition; then a contact detail, which is unique in
        # practice and, in a secret vote, doubles as the address the one-time
        # code goes to; then the combinations, shortest first, that only
        # identify somebody because taken together they are rare.
        CANDIDATES = [
          %w(memberNumber),
          %w(nationalId),
          %w(email),
          %w(phone),
          %w(name surname),
          %w(name surname birthDate),
          %w(surname birthDate),
          %w(name birthDate),
          %w(surname),
          %w(name),
          %w(birthDate)
        ].freeze

        # @param available [Array<String>] the columns kept, in file order.
        # @param duplicates [#call] fields -> how many people share those values.
        # @param blanks [#call] field -> how many people have nothing in it.
        # @return [Array<String>] the details a voter will be asked for.
        def self.derive(available, duplicates:, blanks:)
          pool = Array(available) & Fields::SIMPLE_IDENTIFIERS
          others = pool - %w(token)
          # An access code and nothing else: the only case where the choice
          # costs the admin a secret vote, and still the only way anyone signs
          # in, so it is made and said rather than left empty. With nothing at
          # all to go on, the card says nobody can vote yet.
          return pool & %w(token) if others.empty?

          with_token(best(others, pool, duplicates:, blanks:), pool)
        end

        # Every candidate the list can actually answer, in preference order.
        def self.usable(others)
          CANDIDATES.select { |fields| (fields - others).empty? }
        end
        private_class_method :usable

        # The best the list can do. `max_by` keeps the first of equals, so
        # where two candidates are as good as each other the preference order
        # in {CANDIDATES} is what decides.
        def self.best(others, pool, duplicates:, blanks:)
          candidates = usable(others)
          return [] if candidates.empty?

          candidates.max_by { |fields| rank(fields, pool, duplicates:, blanks:) }
        end
        private_class_method :best

        # Uniqueness first: two people the list cannot tell apart is the one
        # failure that stops the import outright. Then completeness, because a
        # blank cell silently disenfranchises exactly the people in it. A list
        # that can manage neither still gets our best guess, and the form's own
        # validation is what tells the admin about it.
        def self.rank(fields, pool, duplicates:, blanks:)
          unique = duplicates.call(with_token(fields, pool)).to_i.zero?
          complete = fields.all? { |field| blanks.call(field).to_i.zero? }

          (unique ? 2 : 0) + (complete ? 1 : 0)
        end
        private_class_method :rank

        # The access code rides along with whatever identifies the person: on
        # its own it cannot be checked by a secret vote, but next to a name it
        # is the one detail an impersonator does not have.
        def self.with_token(fields, pool)
          return fields unless pool.include?("token")
          return fields if fields.empty?

          fields + %w(token)
        end
        private_class_method :with_token
      end

      # Reads a CSV file once — decoded via {Source}, separator detected,
      # everything parsed into memory — with each row's own line number
      # preserved, so a caller can still point an admin at "line 14" after
      # the request's tempfile is long gone.
      #
      # Deliberately dumber than {Importer}: no field knowledge, no
      # validation, no model. That is {RowMapper}'s job, once an admin has
      # chosen which column means what — this class only has to answer "what
      # is in this file" reliably.
      class Reader
        # @param path [String] a local path to the uploaded file.
        def initialize(path)
          @path = path
        end

        attr_reader :path

        # @return [self]
        # @raise [UnreadableFile] when {Source} cannot decode the file.
        # @raise [CSV::MalformedCSVError] when the file is not valid CSV.
        def load!
          return self if @loaded

          text = Source.new(path).text
          @separator = detect_separator(text)
          parse(text)
          @loaded = true
          self
        end

        # @return [Array<String>] headers, stripped; a blank header is `""`, never `nil`.
        def headers
          load!
          @headers
        end

        def column_count
          load!
          @headers.size
        end

        # @return [Array<Array(Array<String, nil>, Integer)>] `[cells, line_number]`
        #   pairs, in file order. `cells` is aligned to {#headers}; blank
        #   trailing/short rows are padded with `nil`, extra columns are
        #   dropped. All-blank rows are skipped entirely. `line_number` is
        #   1-based, counting the header as line 1, and survives skipped
        #   blank rows (it is not renumbered after a skip).
        def rows
          load!
          @rows
        end

        def row_count
          load!
          @rows.size
        end

        # @return [Integer] rows that are the template's own example line
        #   ({Fields.example_row?}), which is never imported as a person.
        def example_row_count
          load!
          @example_row_count ||= @rows.count { |cells, _number| Fields.example_row?(cells) }
        end

        # @return [Integer] rows that stand for a real person — what an
        #   import will actually be worth.
        def people_count
          row_count - example_row_count
        end

        # @return [Boolean] true when the file had more data rows than {MAX_ROWS}.
        def truncated?
          load!
          @truncated
        end

        # @return [Array<Array<String, nil>>] the cells of the first `count` rows.
        def sample(count = 3)
          load!
          @rows.first(count).map(&:first)
        end

        # @return [Array<String>] up to `count` non-blank values from column `index`.
        def column_samples(index, count = 3)
          load!
          @rows.filter_map { |cells, _number| cells[index] }.compact_blank.first(count)
        end

        def separator
          load!
          @separator
        end

        private

        def parse(text)
          table = CSV.parse(text, col_sep: @separator)
          raw_headers = table.shift || []
          @headers = raw_headers.map { |header| header.to_s.strip }

          @rows = []
          @truncated = false

          table.each_with_index do |cells, index|
            next if cells.all? { |cell| cell.to_s.strip.blank? }

            if @rows.size >= MAX_ROWS
              @truncated = true
              next
            end

            @rows << [align(cells), index + 2] # +1 for zero-based, +1 for the header line
          end
        end

        def align(cells)
          Array.new(@headers.size) { |i| cells[i] }
        end

        # Comma, semicolon or tab, counted on the header line — cheap, and it
        # beats an unreadable "1 column" result. Ties favour `;`, the more
        # common European spreadsheet export.
        def detect_separator(text)
          line = text.each_line.first.to_s
          comma = line.count(",")
          semicolon = line.count(";")
          tab = line.count("\t")

          return "\t" if tab > comma && tab > semicolon
          return "," if comma > semicolon

          ";"
        end
      end

      # Maps {Reader} rows onto {Fields::TARGETS}, cleaning every cell and
      # collecting per-row problems instead of failing the whole file — the
      # same "one bad row must not cost the good ones" contract {Importer}
      # already has, one layer down from any particular model.
      class RowMapper
        Outcome = Struct.new(:rows, :failed_rows, :total, :skipped_examples, keyword_init: true) do
          def initialize(**attributes)
            super(skipped_examples: 0, **attributes)
          end

          def failed? = failed_rows.any?

          def imported_count = rows.size
        end

        # @param reader [Reader]
        # @param mapping [Array<String, nil>] aligned with `reader.headers`;
        #   each element is a {Fields::TARGETS} value, or `nil` to ignore
        #   that column.
        def initialize(reader, mapping)
          @reader = reader
          @mapping = mapping
        end

        attr_reader :reader, :mapping

        # @return [Outcome]
        def call
          reader.load!

          rows = []
          failed_rows = []
          seen = {}
          skipped_examples = 0
          total = 0

          reader.rows.each do |cells, number|
            data, messages = build_row(cells)

            if messages.empty? && example_row?(data)
              skipped_examples += 1
              next
            end

            total += 1
            messages += row_level_messages(data, seen) if messages.empty?

            if messages.empty?
              rows << data
              seen[data] = number
            else
              failed_rows << FailedRow.new(number:, cells: display_cells(cells), messages:)
            end
          end

          Outcome.new(rows:, failed_rows:, total:, skipped_examples:)
        end

        private

        def build_row(cells)
          data = {}
          messages = []

          mapping.each_with_index do |field, index|
            next if field.blank?

            value, error = Fields.clean(field, cells[index])
            if error
              messages << error
            elsif !value.nil?
              data[field] = value
            end
          end

          [data, messages]
        end

        # A row with nothing mapped, or an exact repeat of one already
        # accepted. Only called once a row is otherwise clean, so a real
        # per-cell error is never masked by either of these.
        def row_level_messages(data, seen)
          return [I18n.t("no_values", scope: "decidim.elections.vocdoni.admin.census_file.rows")] if data.empty?
          return [] unless seen.has_key?(data)

          [I18n.t("duplicate_line", scope: "decidim.elections.vocdoni.admin.census_file.rows", line: seen[data])]
        end

        # The template's own example row — {Fields.example} for every mapped
        # column that has a value — must never become a real entry, for the
        # same reason documented at length on {Importer#example_row?}: an
        # example member number is a public credential.
        def example_row?(data)
          return false if data.empty?

          data.all? { |field, value| value == example_value(field) }
        end

        def example_value(field)
          @example_values ||= {}
          @example_values[field] ||= Fields.clean(field, Fields.example(field)).first
        end

        def display_cells(cells)
          hash = {}

          mapping.each_with_index do |field, index|
            next if field.blank?

            hash[reader.headers[index]] = cells[index]
          end

          hash
        end
      end
    end
  end
end
end
