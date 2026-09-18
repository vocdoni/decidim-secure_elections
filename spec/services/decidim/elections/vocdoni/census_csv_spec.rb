# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    describe CensusCsv do
      describe CensusCsv::Template do
        subject(:template) { described_class.new(%w(name surname memberNumber)) }

        it "emits the chosen columns and one filled-in example row" do
          rows = CSV.parse(template.to_csv)

          expect(rows.first).to eq(%w(name surname memberNumber))
          expect(rows.second).to eq(%w(Ada Lovelace 000123))
        end

        it "ignores a column that is not a member field" do
          expect(described_class.new(%w(name sneaky)).headers).to eq(["name"])
        end
      end

      describe CensusCsv::Importer do
        subject(:importer) { described_class.new(election, path) }

        # No credential configured, so nothing beyond the model's own rules
        # applies. Required fields get their own context below.
        let(:election) { create(:vocdoni_election) }

        # Written as bytes rather than as text, because half of what an admin
        # uploads is not UTF-8 and the encoding contexts below need to put
        # exact bytes on disk.
        let(:path) do
          Tempfile.new(["census", ".csv"]).tap do |file|
            file.binmode
            file.write(raw)
            file.rewind
          end.path
        end

        let(:raw) { content }

        # Deliberately not Ada Lovelace. Every fixture here used to be the
        # template's own example row verbatim, which is what let the importer
        # ship for so long without anybody noticing that uploading the template
        # unedited enrolled her — see "the template's example row" below.
        let(:content) do
          <<~CSV
            name,surname,memberNumber
            Rosalind,Franklin,000123
            Grace,Hopper,000124
          CSV
        end

        it "imports every valid row" do
          result = importer.import!

          expect(result.imported_count).to eq(2)
          expect(result.failed_count).to eq(0)
          expect(election.census_members.pluck(:member_number)).to match_array(%w(000123 000124))
        end

        # The whole point of a per-row importer: a couple of bad rows must not
        # cost the admin all the good ones.
        context "when some rows cannot be imported" do
          let(:content) do
            <<~CSV
              name,surname,email
              Rosalind,Franklin,rosalind@example.org
              Grace,Hopper,not-an-email
              ,,
              Alan,Turing,alan@example.org
            CSV
          end

          it "imports the good ones and reports the rest with their line numbers" do
            result = importer.import!

            expect(result.imported_count).to eq(2)
            expect(result.failed_count).to eq(1)
            expect(result.failed_rows.first.number).to eq(3)
            expect(result.failed_rows.first.summary).to match(/email/i)
          end

          it "does not count a blank line as a row" do
            expect(importer.import!.total).to eq(3)
          end
        end

        context "when a value cannot be read" do
          let(:content) do
            <<~CSV
              name,birthDate
              Rosalind,31/02/1990
            CSV
          end

          # Silently dropping the value would only surface once the election is
          # already on chain.
          it "reports it instead of discarding it" do
            result = importer.import!

            expect(result.imported_count).to eq(0)
            expect(result.failed_rows.first.summary).to include("31/02/1990")
          end
        end

        context "when the election needs a field the row does not have" do
          let(:election) { create(:vocdoni_election, census_auth_fields: ["memberNumber"], census_two_fa_fields: ["email"]) }
          let(:content) do
            <<~CSV
              name,memberNumber,email
              Rosalind,000123,rosalind@example.org
              Grace,000124,
            CSV
          end

          # ARCHITECTURE §4c-bis: with 2FA the contact is part of the voter's
          # identity, so a member without it simply cannot vote.
          it "refuses the row and names the missing column" do
            result = importer.import!

            expect(result.imported_count).to eq(1)
            expect(result.failed_rows.first.summary).to match(/email/i)
          end
        end

        describe "header matching" do
          let(:content) do
            <<~CSV
              First name;Last name;Member number
              Rosalind;Franklin;000123
            CSV
          end

          # Semicolons and human-readable headers are what a European
          # spreadsheet export actually produces.
          it "accepts localized headers and a semicolon separator" do
            expect(importer.import!.imported_count).to eq(1)
            expect(election.census_members.first.member_number).to eq("000123")
          end
        end

        # The census resolves a voter by the fields the election authenticates
        # on, so two rows sharing one of them are two ballots for one person.
        # The members table refuses that (`CensusMembersForm#no_duplicates`) and
        # a spreadsheet must not be the way around it.
        context "when a credential is repeated" do
          let(:election) { create(:vocdoni_election, census_auth_fields: ["memberNumber"]) }
          let(:content) do
            <<~CSV
              name,surname,memberNumber
              Rosalind,Franklin,000123
              Grace,Hopper,000124
              Rosalind,Franklin,000123
            CSV
          end

          it "keeps the first row and reports the repeat" do
            result = importer.import!

            expect(result.imported_count).to eq(2)
            expect(result.failed_rows.first.number).to eq(4)
            expect(result.failed_rows.first.summary).to match(/already in the census/i)
          end

          it "matches what is already in the census, ignoring case and spacing" do
            create(:vocdoni_census_member, election:, member_number: " 000124 ")

            expect(importer.import!.imported_count).to eq(1)
          end
        end

        # A field nothing authenticates on is not an identity: two people can
        # share a household phone.
        context "when a field the election does not use is repeated" do
          let(:content) do
            <<~CSV
              name,surname,phone
              Rosalind,Franklin,+34600000000
              Grace,Hopper,+34600000000
            CSV
          end

          it "lets both rows in" do
            expect(importer.import!.imported_count).to eq(2)
          end
        end

        # A refused row is built only to be validated. `CensusMember.new(election:)`
        # writes it into the inverse association's target, where it would go on
        # being returned by `election.census_members` for the rest of the
        # request — as a person in the census who exists nowhere.
        context "when a row is refused" do
          let(:content) do
            <<~CSV
              name,surname,email
              Rosalind,Franklin,rosalind@example.org
              Grace,Hopper,not-an-email
            CSV
          end

          it "does not leave it behind in the election's census" do
            importer.import!

            expect(election.census_members.size).to eq(1)
            expect(election.census_members).to all(be_persisted)
          end
        end

        # What the file is *encoded* as, which used to be assumed rather than
        # asked. Anything that was not valid UTF-8 reached `File#readline` (to
        # sniff the separator) and `CSV.read` as raw bytes, and both answer
        # with a bare `ArgumentError: invalid byte sequence in UTF-8` — nothing
        # rescued it, so the census page died with a 500.
        describe "encodings" do
          let(:content) do
            <<~CSV
              name,surname,memberNumber
              José,Ferrer,000123
            CSV
          end

          shared_examples "a file that reads" do
            it "imports it and keeps the accents" do
              expect(importer.import!.imported_count).to eq(1)
              expect(election.census_members.first.name).to eq("José")
            end
          end

          context "with a UTF-8 byte-order mark" do
            let(:raw) { "\xEF\xBB\xBF".b + content.b }

            it_behaves_like "a file that reads"
          end

          # Excel's "Unicode Text" export, and the one non-UTF-8 encoding worth
          # converting rather than refusing: it always carries a mark, so it is
          # identified exactly rather than guessed at.
          context "when the file is UTF-16LE, as Excel exports it" do
            let(:raw) { "\uFEFF#{content}".encode("UTF-16LE").b }

            it_behaves_like "a file that reads"
          end

          context "when the file is UTF-16BE" do
            let(:raw) { "\uFEFF#{content}".encode("UTF-16BE").b }

            it_behaves_like "a file that reads"
          end

          # Excel's plain "CSV (Comma delimited)" on a Western Windows install.
          # No mark, so it is the fallback for something that is text but is
          # not valid UTF-8.
          context "when the file is Windows-1252" do
            let(:raw) { content.encode("Windows-1252").b }

            it_behaves_like "a file that reads"
          end

          context "when the file is not text at all" do
            # A PNG header. Refused rather than decoded: Windows-1252 would
            # happily turn this into a column called "\x89PNG".
            let(:raw) { "\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR\x00\x00\x01\x00".b }

            it "raises something the form can turn into an error message" do
              expect { importer.import! }.to raise_error(CensusCsv::UnreadableFile)
            end
          end

          # An `.xlsx` is a ZIP. It has no invalid UTF-8 byte in its first line
          # to trip over, which is exactly why the NUL check has to come before
          # the fallback: guessed at, it imports a column called "PK".
          context "when the file is a spreadsheet renamed to .csv" do
            let(:raw) { "PK\x03\x04\x14\x00\x00\x00\x08\x00\x00\x00!\x00".b }

            it "is refused rather than read as gibberish" do
              expect { importer.import! }.to raise_error(CensusCsv::UnreadableFile)
            end
          end

          context "when the file is empty" do
            let(:raw) { "" }

            it "has no columns rather than blowing up" do
              expect(importer.mapping).to be_empty
            end
          end
        end

        # The template ships one filled row so that an admin can see what each
        # column expects. Uploaded unedited it used to import Ada Lovelace as a
        # census member, status "Ready", indistinguishable from a real person —
        # and on an election that authenticates on the member number alone,
        # `000123` is printed in a file anybody can download, so her ballot was
        # anybody's to cast.
        describe "the template's example row" do
          let(:fields) { %w(name surname memberNumber) }
          let(:content) { CensusCsv::Template.new(fields).to_csv }

          it "is not imported" do
            result = importer.import!

            expect(result.imported_count).to eq(0)
            expect(election.census_members.reload).to be_empty
          end

          it "is reported rather than dropped in silence" do
            expect(importer.import!.skipped_examples_count).to eq(1)
          end

          it "is not counted as a row that was read" do
            expect(importer.import!.total).to eq(0)
          end

          it "is not reported as a failure either" do
            expect(importer.import!.failed_count).to eq(0)
          end

          context "with every column the template can carry" do
            let(:fields) { Vocdoni::CensusMember::FIELDS }

            it "is still recognised" do
              expect(importer.import!.skipped_examples_count).to eq(1)
            end
          end

          context "when the admin filled the template in around it" do
            let(:content) do
              <<~CSV
                name,surname,memberNumber
                Ada,Lovelace,000123
                Grace,Hopper,000124
              CSV
            end

            it "skips only the example and imports the person" do
              result = importer.import!

              expect(result.skipped_examples_count).to eq(1)
              expect(result.imported_count).to eq(1)
              expect(election.census_members.pluck(:member_number)).to eq(["000124"])
            end
          end

          # The match is strict on purpose: a real person must not be dropped
          # because their name happens to be the one in the template.
          context "when a single value differs" do
            let(:content) do
              <<~CSV
                name,surname,memberNumber
                Ada,Lovelace,000124
              CSV
            end

            it "is an ordinary row again" do
              result = importer.import!

              expect(result.skipped_examples_count).to eq(0)
              expect(result.imported_count).to eq(1)
            end
          end

          context "when a column the example fills is left empty" do
            let(:content) do
              <<~CSV
                name,surname,memberNumber
                Ada,Lovelace,
              CSV
            end

            it "is an ordinary row again" do
              expect(importer.import!.skipped_examples_count).to eq(0)
            end
          end

          # Columns we do not recognise are not imported, so they cannot make
          # the row a person and are not compared.
          context "when the admin added a column of their own" do
            let(:content) do
              <<~CSV
                name,surname,memberNumber,notes
                Ada,Lovelace,000123,delete me
              CSV
            end

            it "is still recognised" do
              expect(importer.import!.skipped_examples_count).to eq(1)
            end
          end
        end

        context "when a column is not recognised" do
          let(:content) do
            <<~CSV
              name,favourite colour
              Rosalind,green
            CSV
          end

          it "ignores it and says which one" do
            expect(importer.unknown_headers).to eq(["favourite colour"])
            expect(importer.import!.imported_count).to eq(1)
          end
        end
      end
    end
  end
end
end
