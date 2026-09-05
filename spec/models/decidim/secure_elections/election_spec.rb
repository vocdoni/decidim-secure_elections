# frozen_string_literal: true

require "spec_helper"

module Decidim
  module SecureElections
    describe Election do
      subject(:election) { create(:vocdoni_election) }

      it { is_expected.to be_valid }

      describe "#editable? / #on_chain?" do
        it "is editable while there is no process id" do
          expect(election).to be_editable
          expect(election).not_to be_on_chain
        end

        it "is frozen as soon as a process id is stored" do
          election.update!(vocdoni_process_id: "6885f0c2c1a4e2f0b1d33a01")

          expect(election).not_to be_editable
          expect(election).to be_on_chain
        end
      end

      describe "#census_configured?" do
        it "is false when no authentication field is selected" do
          expect(election.census_auth_fields).to eq([])
          expect(election).not_to be_census_configured
        end

        it "is false when the stored value is blank rather than empty" do
          election.update!(census_auth_fields: ["", nil])

          expect(election).not_to be_census_configured
        end

        it "is true once a field is selected" do
          election.update!(census_auth_fields: ["memberNumber"])

          expect(election).to be_census_configured
        end
      end

      describe "#auth_only?" do
        it "is true with no two-factor field" do
          expect(election).to be_auth_only
        end

        it "is false once a two-factor field is selected" do
          election.update!(census_two_fa_fields: ["email"])

          expect(election).not_to be_auth_only
        end
      end

      describe "wizard steps" do
        let(:election) { create(:vocdoni_election, :ready_to_publish) }

        it "reports every step complete when everything is filled in" do
          expect(election).to be_details_complete
          expect(election).to be_questions_complete
          expect(election).to be_census_complete
          expect(election).to be_calendar_complete
          expect(election).to be_ready_for_setup
        end

        it "is not ready for setup without a census" do
          election.update!(census_auth_fields: [])

          expect(election).not_to be_ready_for_setup
        end

        it "is not ready for setup when a question has a single answer" do
          election.questions.first.answers.last.destroy!
          election.reload

          expect(election).not_to be_questions_complete
          expect(election).not_to be_ready_for_setup
        end

        it "is not ready for setup without an end date" do
          election.update!(end_at: nil)

          expect(election).not_to be_calendar_complete
          expect(election).not_to be_ready_for_setup
        end

        it "is not ready for setup once it is on chain" do
          election.update!(vocdoni_process_id: "6885f0c2c1a4e2f0b1d33a01")

          expect(election).not_to be_ready_for_setup
        end
      end

      # The rule the navigation, the controllers and the permission class all
      # ask, so that they cannot drift apart.
      describe "step reachability" do
        context "with nothing but a title" do
          let(:election) { create(:vocdoni_election, end_at: nil) }

          it "opens the details and the ballot, and nothing beyond" do
            expect(election.step_reachable?(:details)).to be(true)
            expect(election.step_reachable?(:questions)).to be(true)
            expect(election.step_reachable?(:census)).to be(false)
            expect(election.step_reachable?(:calendar)).to be(false)
            expect(election.step_reachable?(:publish)).to be(false)
            expect(election.step_reachable?(:monitor)).to be(false)
          end

          it "names the first thing in the way, not the last" do
            expect(election.step_blocker(:publish)).to eq(:questions_incomplete)
            expect(election.step_blocker(:monitor)).to eq(:not_on_chain)
          end

          it "sends an admin forward rather than back to the beginning" do
            expect(election.furthest_reachable_step).to eq(:questions)
          end
        end

        context "with an unfinished title" do
          let(:election) { create(:vocdoni_election, title: { en: "" }) }

          it "locks everything after the details" do
            expect(election.step_reachable?(:details)).to be(true)
            expect(election.step_blocker(:questions)).to eq(:details_incomplete)
            expect(election.furthest_reachable_step).to eq(:details)
          end
        end

        context "when everything is filled in" do
          let(:election) { create(:vocdoni_election, :ready_to_publish) }

          it "opens the publish step and no further" do
            expect(election.step_reachable?(:publish)).to be(true)
            expect(election.step_reachable?(:monitor)).to be(false)
            expect(election.furthest_reachable_step).to eq(:publish)
            expect(election.completed_steps_count).to eq(4)
          end
        end

        context "when the election is on chain" do
          let(:election) { create(:vocdoni_election, :on_chain) }

          it "keeps every content step reachable, read-only" do
            Decidim::SecureElections::Election::CONTENT_STEPS.each do |step|
              expect(election.step_reachable?(step)).to be(true)
            end
          end

          it "closes the publish step and opens the monitor" do
            expect(election.step_blocker(:publish)).to eq(:locked_on_chain)
            expect(election.step_reachable?(:monitor)).to be(true)
            expect(election.furthest_reachable_step).to eq(:monitor)
          end
        end

        context "when the publish job is still in flight" do
          let(:election) { create(:vocdoni_election, :ready_to_publish, status: "publishing") }

          it "opens the monitor so the admin can watch it land" do
            expect(election.step_reachable?(:monitor)).to be(true)
            expect(election.furthest_reachable_step).to eq(:monitor)
          end
        end
      end

      describe ".normalize_status" do
        it "downcases the API vocabulary" do
          expect(described_class.normalize_status("READY")).to eq("ready")
          expect(described_class.normalize_status("PAUSED")).to eq("paused")
        end

        it "maps the API's ONGOING onto ready" do
          expect(described_class.normalize_status("ONGOING")).to eq("ready")
        end

        it "returns nil for anything it does not recognise" do
          expect(described_class.normalize_status("WHATEVER")).to be_nil
          expect(described_class.normalize_status(nil)).to be_nil
        end
      end

      describe "#turnout" do
        it "is nil without a known census size" do
          election.update!(census_size: 0, votes_count: 5)

          expect(election.turnout).to be_nil
        end

        it "is the share of the census that voted" do
          election.update!(census_size: 4, votes_count: 1)

          expect(election.turnout).to eq(25.0)
        end
      end

      describe "#manual_start?" do
        # The old meaning ("start_at is blank") was renamed under the
        # naming-gotcha rule: `manual_start` is now an explicit admin
        # decision, stored as its own boolean column. A blank `start_at`
        # with `manual_start = false` means "opens on publish", which is
        # a distinct state.
        it "is true when the admin explicitly ticked the manual_start checkbox" do
          election.update!(manual_start: true)

          expect(election).to be_manual_start
        end

        it "is false by default (manual_start is a deliberate admin choice)" do
          expect(election).not_to be_manual_start
        end

        it "stays false when start_at is blank without the checkbox" do
          election.update!(manual_start: false, start_at: nil)

          expect(election).not_to be_manual_start
        end
      end

      # The admin used to lead with `status`, which is the API's vocabulary: an
      # election that was open and taking votes said "Ready", and every admin
      # screen made a live election look dormant at once.
      describe "#display_state" do
        it "is a draft while nothing is on chain" do
          expect(election.display_state).to eq(:draft)
        end

        it "says voting is open for a live election, not 'ready'" do
          election = create(:vocdoni_election, :on_chain, start_at: 1.hour.ago, end_at: 1.hour.from_now)

          expect(election.status).to eq("ready")
          expect(election.display_state).to eq(:ongoing)
        end

        it "says voting is open for a live election that starts on publication" do
          election = create(:vocdoni_election, :on_chain, start_at: nil, end_at: 1.hour.from_now)

          expect(election.display_state).to eq(:ongoing)
        end

        it "is scheduled before its start time" do
          election = create(:vocdoni_election, :on_chain, start_at: 1.hour.from_now, end_at: 2.hours.from_now)

          expect(election.display_state).to eq(:scheduled)
        end

        # The upstream status lags the calendar. The admin must not be told an
        # election is open when its own end time has passed.
        it "is ended past its end time even while upstream still says ready" do
          election = build(:vocdoni_election, status: "ready", start_at: 2.hours.ago, end_at: 1.hour.ago,
                                              vocdoni_process_id: "6885f0c2c1a4e2f0b1d33a01")

          expect(election.display_state).to eq(:ended)
        end

        it "agrees with the badge the public side renders" do
          election = create(:vocdoni_election, :on_chain, start_at: 1.hour.ago, end_at: 1.hour.from_now)

          expect(election.display_state).to eq(Decidim::SecureElections::ElectionStatusCell.state_for(election))
        end
      end

      describe "#started_at" do
        it "is the scheduled start when there is one" do
          start_at = 1.hour.ago
          election.update!(start_at:)

          expect(election.started_at).to be_within(1.second).of(start_at)
        end

        it "is nil while the election is still a draft with no schedule" do
          expect(election.started_at).to be_nil
        end

        # "Starts when published" is a lie once the election *is* published, and
        # it is the lie that made a running election look dormant. With no
        # column for the publication instant, the action log is what remembers.
        it "is the moment publication was requested for an election that starts on publication" do
          election = create(:vocdoni_election, :on_chain, start_at: nil)
          user = create(:user, :admin, :confirmed, organization: election.component.organization)

          # Exactly what `SetupElection` records when the admin presses the
          # irreversible button.
          Decidim.traceability.perform_action!(:setup, election, user, visibility: "all") { election }

          expect(election.started_at).to be_within(1.minute).of(Time.current)
        end
      end

      describe "validations" do
        it "rejects an end time before the start time" do
          election.start_at = 2.days.from_now
          election.end_at = 1.day.from_now

          expect(election).not_to be_valid
          expect(election.errors[:end_at]).not_to be_empty
        end

        it "rejects an unknown status" do
          election.status = "whatever"

          expect(election).not_to be_valid
        end
      end

      describe "#last_error_message" do
        it "is nil when nothing failed" do
          expect(election.last_error_message).to be_nil
        end

        it "reads the reserved key of results_cache" do
          election.update!(results_cache: { "error" => { "message" => "boom" } })

          expect(election.last_error_message).to eq("boom")
        end
      end
    end
  end
end
