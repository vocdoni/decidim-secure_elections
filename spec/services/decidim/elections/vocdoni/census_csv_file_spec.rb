# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    describe CensusCsv do
      # Written as bytes rather than as text, same reasoning as
      # census_csv_spec: half of what an admin uploads is not UTF-8, and the
      # encoding contexts below need exact bytes on disk.
      def tempfile_path(raw)
        Tempfile.new(["census", ".csv"]).tap do |file|
          file.binmode
          file.write(raw)
          file.rewind
        end.path
      end

      describe CensusCsv::Reader do
        subject(:reader) { described_class.new(path) }

        let(:path) { tempfile_path(raw) }
        let(:raw) { content.b }

        describe "separator detection" do
          context "with commas" do
            let(:content) { "name,surname\nAda,Lovelace\n" }

            it "detects the comma" do
              expect(reader.load!.separator).to eq(",")
            end
          end

          context "with semicolons" do
            let(:content) { "name;surname\nAda;Lovelace\n" }

            it "detects the semicolon" do
              expect(reader.load!.separator).to eq(";")
            end
          end

          context "with tabs" do
            let(:content) { "name\tsurname\nAda\tLovelace\n" }

            it "detects the tab" do
              expect(reader.load!.separator).to eq("\t")
            end
          end

          context "when comma and semicolon are tied" do
            let(:content) { "a,b;c\n1,2;3\n" }

            it "prefers the semicolon" do
              expect(reader.load!.separator).to eq(";")
            end
          end
        end

        describe "encodings" do
          let(:content) { "name,surname\nNúñez,García\n" }

          context "with a UTF-8 byte-order mark" do
            let(:raw) { "\xEF\xBB\xBF".b + content.b }

            it "decodes it and drops the mark from the first header" do
              reader.load!

              expect(reader.headers).to eq(%w(name surname))
              expect(reader.rows.first.first).to eq(%w(Núñez García))
            end
          end

          context "when the file is Windows-1252" do
            let(:raw) { content.encode("Windows-1252").b }

            it "decodes the accented characters" do
              reader.load!

              expect(reader.rows.first.first).to eq(%w(Núñez García))
            end
          end
        end

        context "with a blank header" do
          let(:content) { "name,,surname\nAda,x,Lovelace\n" }

          it "keeps it as an empty string, never nil" do
            expect(reader.load!.headers).to eq(["name", "", "surname"])
          end
        end

        context "with blank lines among real ones" do
          let(:content) do
            <<~CSV
              name,surname
              Ada,Lovelace

              ,
              Grace,Hopper
            CSV
          end

          it "skips them and keeps the real rows' true line numbers" do
            reader.load!

            expect(reader.rows.map(&:last)).to eq([2, 5])
            expect(reader.rows.map(&:first)).to eq([%w(Ada Lovelace), %w(Grace Hopper)])
            expect(reader.row_count).to eq(2)
          end

          it "is not truncated" do
            expect(reader.load!.truncated?).to be(false)
          end
        end

        context "with more rows than MAX_ROWS" do
          before { stub_const("Decidim::Elections::Vocdoni::CensusCsv::MAX_ROWS", 3) }

          let(:content) do
            "name\n#{(1..5).map { |i| "Person#{i}\n" }.join}"
          end

          it "keeps only MAX_ROWS rows and reports the truncation" do
            reader.load!

            expect(reader.row_count).to eq(3)
            expect(reader.rows.map { |cells, _number| cells.first }).to eq(%w(Person1 Person2 Person3))
            expect(reader.truncated?).to be(true)
          end
        end

        describe "#sample and #column_samples" do
          let(:content) do
            <<~CSV
              name,surname
              Ada,Lovelace
              Grace,Hopper
              ,
              Rosalind,Franklin
            CSV
          end

          it "#sample returns the first rows' cells" do
            expect(reader.load!.sample(2)).to eq([%w(Ada Lovelace), %w(Grace Hopper)])
          end

          it "#column_samples returns non-blank values from one column" do
            expect(reader.load!.column_samples(0, 2)).to eq(%w(Ada Grace))
          end
        end

        context "with malformed CSV" do
          let(:content) { %(name,surname\n"Ada,Lovelace\n) }

          it "raises CSV::MalformedCSVError" do
            expect { reader.load! }.to raise_error(CSV::MalformedCSVError)
          end
        end

        it "is idempotent" do
          raw_content = "name\nAda\n"
          idempotent_path = tempfile_path(raw_content.b)
          idempotent_reader = described_class.new(idempotent_path)

          expect(idempotent_reader.load!.load!).to equal(idempotent_reader)
          expect(idempotent_reader.row_count).to eq(1)
        end

        context "with an unreadable (binary) file" do
          let(:raw) { "\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR\x00\x00\x01\x00".b }

          it "raises UnreadableFile" do
            expect { reader.load! }.to raise_error(CensusCsv::UnreadableFile)
          end
        end
      end

      describe CensusCsv::Fields do
        describe ".suggest" do
          {
            "Nº socio" => "memberNumber",
            "Correo electrónico" => "email",
            "DNI" => "nationalId",
            "Fecha nacimiento" => "birthDate",
            "Código" => "token"
          }.each do |header, field|
            it "maps #{header.inspect} to #{field.inspect}" do
              expect(described_class.suggest(header)).to eq(field)
            end
          end

          it "returns nil when nothing matches" do
            expect(described_class.suggest("Favourite colour")).to be_nil
          end

          it "returns nil for a blank header" do
            expect(described_class.suggest("  ")).to be_nil
          end

          # The downloadable template can use each target's own label as its
          # header, and a file built from it must round-trip when re-uploaded.
          it "round-trips every target's own label" do
            described_class::TARGETS.each do |field|
              expect(described_class.suggest(described_class.label(field))).to eq(field)
            end
          end
        end

        describe ".label, .hint and .example" do
          it "returns a label for every target" do
            described_class::TARGETS.each do |field|
              expect(described_class.label(field)).to be_a(String).and be_present
            end
          end

          it "returns a hint for every target" do
            described_class::TARGETS.each do |field|
              expect(described_class.hint(field)).to be_a(String).and be_present
            end
          end

          it "returns an example for every target" do
            described_class::TARGETS.each do |field|
              expect(described_class.example(field)).to be_a(String).and be_present
            end
          end
        end

        describe ".clean" do
          it "returns [nil, nil] for a blank value" do
            expect(described_class.clean("name", "  ")).to eq([nil, nil])
            expect(described_class.clean("name", nil)).to eq([nil, nil])
          end

          it "strips and collapses whitespace for a plain field" do
            expect(described_class.clean("name", "  Ada   Lovelace  ")).to eq(["Ada Lovelace", nil])
          end

          describe "email" do
            it "downcases a valid address" do
              expect(described_class.clean("email", "Ada@Example.ORG")).to eq(["ada@example.org", nil])
            end

            it "rejects an invalid address" do
              value, error = described_class.clean("email", "not-an-email")

              expect(value).to be_nil
              expect(error).to include("not-an-email")
            end
          end

          describe "birthDate" do
            it "accepts ISO format (YYYY-MM-DD)" do
              expect(described_class.clean("birthDate", "1990-01-31").first).to eq("1990-01-31")
            end

            it "accepts YYYY/MM/DD" do
              expect(described_class.clean("birthDate", "1990/01/31").first).to eq("1990-01-31")
            end

            it "accepts DD/MM/YYYY (day first)" do
              expect(described_class.clean("birthDate", "31/01/1990").first).to eq("1990-01-31")
            end

            it "accepts DD-MM-YYYY" do
              expect(described_class.clean("birthDate", "31-01-1990").first).to eq("1990-01-31")
            end

            it "accepts DD.MM.YYYY" do
              expect(described_class.clean("birthDate", "31.01.1990").first).to eq("1990-01-31")
            end

            it "rejects a date that does not exist" do
              value, error = described_class.clean("birthDate", "31/02/1990")

              expect(value).to be_nil
              expect(error).to include("31/02/1990")
            end
          end

          describe "phone" do
            it "keeps a leading plus and digits only" do
              expect(described_class.clean("phone", "+34 600-00 00 00").first).to eq("+34600000000")
            end

            it "keeps digits only when there is no plus" do
              expect(described_class.clean("phone", "600 00 00 00").first).to eq("600000000")
            end

            it "rejects fewer than 6 digits" do
              value, error = described_class.clean("phone", "12345")

              expect(value).to be_nil
              expect(error).to be_present
            end
          end

          describe "weight" do
            it "returns a positive integer" do
              expect(described_class.clean("weight", "3")).to eq([3, nil])
            end

            it "rejects zero" do
              value, error = described_class.clean("weight", "0")

              expect(value).to be_nil
              expect(error).to be_present
            end

            it "rejects a negative number" do
              value, error = described_class.clean("weight", "-1")

              expect(value).to be_nil
              expect(error).to be_present
            end

            it "rejects a non-numeric value" do
              value, error = described_class.clean("weight", "abc")

              expect(value).to be_nil
              expect(error).to be_present
            end
          end

          describe "memberNumber, nationalId and token" do
            it "keeps the value as-is, case included" do
              expect(described_class.clean("memberNumber", "000123").first).to eq("000123")
              expect(described_class.clean("nationalId", "12345678z").first).to eq("12345678z")
              expect(described_class.clean("token", "A1b2C3").first).to eq("A1b2C3")
            end
          end
        end

        describe ".comparable" do
          it "downcases a String result" do
            expect(described_class.comparable("email", "Ada@Example.org")).to eq("ada@example.org")
            expect(described_class.comparable("token", "A1B2C3")).to eq("a1b2c3")
          end

          it "does not downcase an Integer result" do
            expect(described_class.comparable("weight", "3")).to eq(3)
          end

          it "returns nil for a blank value" do
            expect(described_class.comparable("name", "")).to be_nil
          end
        end
      end

      describe CensusCsv::RowMapper do
        subject(:mapper) { described_class.new(reader, mapping) }

        let(:reader) { CensusCsv::Reader.new(path) }
        let(:path) { tempfile_path(content.b) }

        context "with a mix of good, bad, duplicate and empty rows, and an ignored column" do
          let(:content) do
            <<~CSV
              Name,Email,Extra
              Rosalind,rosalind@example.org,ignored
              Grace,not-an-email,ignored
              Rosalind,rosalind@example.org,ignored
              ,,only-extra
            CSV
          end
          let(:mapping) { ["name", "email", nil] }

          it "imports the one good, non-duplicate row" do
            outcome = mapper.call

            expect(outcome.imported_count).to eq(1)
            expect(outcome.rows).to eq([{ "name" => "Rosalind", "email" => "rosalind@example.org" }])
          end

          it "reports the bad, duplicate and empty rows with their line numbers" do
            outcome = mapper.call

            expect(outcome.failed?).to be(true)
            expect(outcome.failed_rows.map(&:number)).to eq([3, 4, 5])
          end

          it "explains why the email row failed" do
            row = mapper.call.failed_rows.find { |r| r.number == 3 }

            expect(row.summary).to include("not-an-email")
          end

          it "explains the duplicate against its earlier line" do
            row = mapper.call.failed_rows.find { |r| r.number == 4 }

            expect(row.summary).to include("line 2")
          end

          it "explains the row with no values in the kept columns" do
            row = mapper.call.failed_rows.find { |r| r.number == 5 }

            expect(row.summary).to be_present
          end

          it "keeps only the mapped columns in a failed row's cells" do
            row = mapper.call.failed_rows.find { |r| r.number == 3 }

            expect(row.cells).to eq({ "Name" => "Grace", "Email" => "not-an-email" })
          end

          it "counts every attempted row (good, bad, duplicate and empty) in total" do
            expect(mapper.call.total).to eq(4)
          end

          it "has no skipped examples" do
            expect(mapper.call.skipped_examples).to eq(0)
          end
        end

        context "with the template's own example row among real ones" do
          let(:content) do
            <<~CSV
              Name,Email,Weight
              Ada,ada@example.org,1
              Rosalind,rosalind@example.org,2
              Grace,grace@example.org,3
            CSV
          end
          let(:mapping) { %w(name email weight) }

          it "skips the example row without importing or failing it" do
            outcome = mapper.call

            expect(outcome.imported_count).to eq(2)
            expect(outcome.failed?).to be(false)
            expect(outcome.skipped_examples).to eq(1)
            expect(outcome.rows.map { |row| row["name"] }).to match_array(%w(Rosalind Grace))
          end

          it "does not count the skipped example row in total" do
            expect(mapper.call.total).to eq(2)
          end
        end

        context "with no rows at all" do
          let(:content) { "name,email\n" }
          let(:mapping) { %w(name email) }

          it "imports nothing and fails nothing" do
            outcome = mapper.call

            expect(outcome.imported_count).to eq(0)
            expect(outcome.failed?).to be(false)
            expect(outcome.skipped_examples).to eq(0)
          end
        end
      end

      describe CensusCsv::RowMapper::Outcome do
        it "defaults skipped_examples to 0" do
          outcome = described_class.new(rows: [], failed_rows: [], total: 0)

          expect(outcome.skipped_examples).to eq(0)
        end
      end
    end
  end
end
end
