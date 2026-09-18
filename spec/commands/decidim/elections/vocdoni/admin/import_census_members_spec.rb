# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    module Admin
      describe ImportCensusMembers do
        subject(:command) { described_class.new(form, election, current_user) }

        let(:organization) { create(:organization) }
        let(:current_user) { create(:user, :admin, :confirmed, organization:) }
        let(:election) { create(:vocdoni_election, census_auth_fields: ["memberNumber"]) }
        let(:context) { { current_organization: organization, current_user:, election: } }

        let(:content) do
          <<~CSV
            name,surname,memberNumber
            Rosalind,Franklin,000123
            Grace,Hopper,000124
          CSV
        end

        let(:blob) do
          ActiveStorage::Blob.create_and_upload!(
            io: StringIO.new(content),
            filename: "census.csv",
            content_type: "text/csv"
          )
        end

        let(:form) { CensusImportForm.from_params(census_import: { file: blob.signed_id, replace: }).with_context(context) }
        let(:replace) { false }

        # What the controller actually receives. The command is run the way a
        # controller runs it — `Decidim::Command.call` with a block — because
        # the arguments a broadcast carries are half the contract and the
        # `broadcast` matcher alone does not check them.
        def broadcast_from(event)
          payload = :nothing
          described_class.call(form, election, current_user) do
            on(event) { |value| payload = value }
          end
          payload
        end

        it "imports the file and reports how many landed" do
          expect { command.call }.to broadcast(:ok)

          expect(election.census_members.count).to eq(2)
          expect(election.reload.census_size).to eq(2)
        end

        it "hands the caller a result it can report from" do
          result = broadcast_from(:ok)

          expect(result.imported_count).to eq(2)
          expect(result.total).to eq(2)
          expect(result).not_to be_any_failures
        end

        context "when some rows fail" do
          let(:content) do
            <<~CSV
              name,surname,memberNumber
              Rosalind,Franklin,000123
              Grace,Hopper,
            CSV
          end

          # Partial success is the normal case, not a failure: the good rows go
          # in and the bad ones come back with their line numbers.
          it "imports the good rows and reports the rest" do
            expect { command.call }.to broadcast(:ok)

            expect(election.census_members.count).to eq(1)
          end
        end

        context "when nothing can be imported" do
          let(:content) do
            <<~CSV
              name,surname,memberNumber
              Grace,Hopper,
            CSV
          end

          it { expect { command.call }.to broadcast(:invalid) }

          # The caller renders the per-row report from this. Broadcasting
          # `:invalid` bare would leave it with nothing to say beyond "no".
          it "still carries the result, so the rows can be reported" do
            result = broadcast_from(:invalid)

            expect(result.failed_count).to eq(1)
            expect(result.failed_rows.first.number).to eq(2)
            expect(result.failed_rows.first.summary).to match(/member number/i)
          end
        end

        # Nothing was read at all, so there is no per-row report to give: the
        # caller has to fall back on the form's own errors. The three ways this
        # happens are all reachable from the upload field.
        context "when the file itself cannot be used" do
          shared_examples "a refused file" do
            it "broadcasts :invalid without a result" do
              expect(broadcast_from(:invalid)).to be_nil
              expect(election.census_members.count).to eq(0)
            end
          end

          context "when no file was chosen" do
            let(:form) { CensusImportForm.from_params(census_import: { replace: }).with_context(context) }

            it_behaves_like "a refused file"

            it "says so on the form" do
              command.call
              expect(form.errors[:file]).to be_present
            end
          end

          context "when the file has no column this census knows" do
            let(:content) do
              <<~CSV
                colour,shape
                red,round
              CSV
            end

            it_behaves_like "a refused file"

            it "names the problem rather than the rows" do
              command.call
              expect(form.errors.full_messages.to_sentence).to match(/no column this census recognises/i)
            end
          end

          context "when the file is not a CSV at all" do
            let(:content) { "name,surname\n\"unterminated,quote\n" }

            it_behaves_like "a refused file"
          end
        end

        # Two rows sharing a credential are two ballots for one person. The
        # members table refuses that outright; a spreadsheet must not be the way
        # around it.
        context "when the file repeats somebody" do
          let(:content) do
            <<~CSV
              name,surname,memberNumber
              Rosalind,Franklin,000123
              Rosalind,Franklin again,000123
            CSV
          end

          it "keeps the first and reports the second" do
            result = broadcast_from(:ok)

            expect(election.census_members.count).to eq(1)
            expect(result.failed_rows.first.number).to eq(3)
            expect(result.failed_rows.first.summary).to match(/already in the census/i)
          end
        end

        context "when the file repeats somebody already in the census" do
          before { create(:vocdoni_census_member, election:, member_number: "000123") }

          it "refuses the row instead of doubling the person" do
            result = broadcast_from(:ok)

            expect(result.imported_count).to eq(1)
            expect(result.failed_rows.first.summary).to include("000123")
            expect(election.census_members.where(member_number: "000123").count).to eq(1)
          end
        end

        # A refused row is built to be validated and then thrown away. It used
        # to stay in `election.census_members` for the rest of the request,
        # which is what made a failed import re-render the census page with
        # people in it that exist nowhere.
        context "when rows are refused" do
          let(:content) do
            <<~CSV
              name,surname,memberNumber
              Rosalind,Franklin,000123
              Grace,Hopper,
            CSV
          end

          it "leaves nothing unsaved behind in the census" do
            command.call

            expect(election.census_members.size).to eq(1)
            expect(election.census_members.map(&:persisted?)).to all(be(true))
          end
        end

        context "when replacing the census" do
          let(:replace) { true }

          before { create(:vocdoni_census_member, election:) }

          it "removes everybody first" do
            command.call

            expect(election.census_members.count).to eq(2)
          end

          # Without this the flash could only say "2 people were added", which
          # an admin who mis-ticked the box reads as "old plus new".
          it "reports how many that cost" do
            result = broadcast_from(:ok)

            expect(result.removed_count).to eq(1)
            expect(result.imported_count).to eq(2)
          end

          # The destructive half used to run first and unconditionally. A file
          # whose every row was rejected therefore emptied the census and
          # reported only "nothing could be imported": no census, no
          # explanation, no undo.
          context "when the file turns out to be unusable" do
            let(:content) do
              <<~CSV
                name,surname,memberNumber
                Grace,Hopper,
              CSV
            end

            it "leaves the census exactly as it was" do
              expect { command.call }.to broadcast(:invalid)

              expect(election.census_members.count).to eq(1)
              expect(election.reload.census_size).to eq(1)
            end
          end

          context "when the file cannot be read at all" do
            let(:content) { "\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR".b }

            it "does not touch the census, and does not raise" do
              expect { command.call }.to broadcast(:invalid)

              expect(election.census_members.count).to eq(1)
            end
          end
        end

        context "when adding to the census" do
          before { create(:vocdoni_census_member, election:) }

          it "keeps the people already there" do
            command.call

            expect(election.census_members.count).to eq(3)
          end
        end

        context "when the election is already on chain" do
          before { election.update!(vocdoni_process_id: "6885f0c2c1a4e2f0b1d33a01") }

          it "refuses to change who may vote" do
            expect { command.call }.to broadcast(:invalid)
            expect(election.census_members.count).to eq(0)
          end
        end
      end
    end
  end
end
end
