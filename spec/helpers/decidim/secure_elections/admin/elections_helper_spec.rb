# frozen_string_literal: true

require "spec_helper"

module Decidim
  module SecureElections
    module Admin
      describe ElectionsHelper do
        let(:organization) { create(:organization) }
        let(:participatory_space) { create(:participatory_process, organization:) }
        let(:component) { create(:vocdoni_component, participatory_space:) }

        # Trashing is the most destructive control on the elections index and it
        # carried the weakest guard on it: one generic sentence, while the
        # neighbouring "Unpublish" already explained that an election running on
        # chain keeps accepting votes.
        describe "#vocdoni_trash_confirm_data" do
          subject(:data) { helper.vocdoni_trash_confirm_data(election) }

          context "with a draft that has never been on chain" do
            let(:election) { create(:vocdoni_election, component:) }

            it "says there is nothing on chain to lose" do
              expect(helper.vocdoni_trash_confirm_key(election)).to eq("draft")
              expect(data[:confirm]).to include("Nothing has been written to the blockchain")
            end
          end

          context "with an election that is open and taking votes" do
            let(:election) { create(:vocdoni_election, :on_chain, component:, end_at: 1.day.from_now) }

            it "is picked from the display state, not the upstream status" do
              expect(election.status).to eq("ready")
              expect(helper.vocdoni_trash_confirm_key(election)).to eq("voting_open")
            end

            it "says that trashing does not stop the vote" do
              expect(data[:confirm]).to include("does not stop it")
              expect(data[:confirm]).to include("votes will keep being accepted")
            end

            it "says what participants lose" do
              expect(data[:confirm]).to include("use to open their ballot")
            end

            it "points at the control that does stop it" do
              expect(data[:confirm]).to include("end or cancel the election on the monitoring page")
            end

            it "names both buttons of a dialog that hard-codes OK and Cancel" do
              expect(data[:confirm]).to include("Choose OK")
              expect(data[:confirm]).to include("or Cancel")
            end

            it "leads with the state rather than with the question" do
              expect(data[:"confirm-title"]).to eq("This election is open and taking votes")
            end
          end

          context "with an election that is on chain and over" do
            let(:election) { create(:vocdoni_election, :on_chain, component:, status: "ended", end_at: 1.day.ago) }

            it "says the process and its results stay on chain" do
              expect(helper.vocdoni_trash_confirm_key(election)).to eq("on_chain")
              expect(data[:confirm]).to include("stay public on Vocdoni")
            end
          end

          it "asks for a bin rather than the dialog's default icon" do
            election = create(:vocdoni_election, component:)

            expect(helper.vocdoni_trash_confirm_data(election)[:"confirm-icon"]).to eq("delete-bin-line")
          end
        end

        # "Ready" is the Vocdoni API's word for a question that is on chain and
        # has not been stopped. Read as English on the monitor — underneath a
        # headline saying "Voting open" — it says the opposite of what is
        # happening, so the badge speaks the product's own language instead.
        describe "#vocdoni_question_status_label" do
          subject(:label) { helper.vocdoni_question_status_label(question) }

          let(:question) { election.questions.first }

          context "with a question that is open and taking votes" do
            let(:election) { create(:vocdoni_election, :on_chain, component:, end_at: 1.day.from_now) }

            it "reads the way the election's own badge reads" do
              expect(question.vocdoni_status).to eq("ready")
              expect(helper.vocdoni_question_display_state(question)).to eq(:ongoing)
              expect(label).to include("Voting open")
              expect(label).not_to include("Ready")
            end
          end

          context "with a question whose election has not opened yet" do
            let(:election) do
              create(:vocdoni_election, :on_chain, component:, start_at: 1.day.from_now, end_at: 2.days.from_now)
            end

            it "does not claim voting is open" do
              expect(helper.vocdoni_question_display_state(question)).to eq(:scheduled)
              expect(label).to include("Scheduled")
            end
          end

          context "with a question that has been stopped on its own" do
            let(:election) { create(:vocdoni_election, :on_chain, component:, end_at: 1.day.from_now) }

            before { question.update!(vocdoni_status: "paused") }

            it "keeps the per-question truth rather than the election's" do
              expect(helper.vocdoni_question_display_state(question)).to eq(:paused)
              expect(label).to include("Paused")
            end
          end

          context "with a question that has never reached the chain" do
            let(:election) { create(:vocdoni_election, :with_questions, component:) }

            it "is a draft" do
              expect(helper.vocdoni_question_display_state(question)).to eq(:draft)
              expect(label).to include("Draft")
            end
          end
        end

        # `Decidim::FormBuilder` renders the per-field language switcher as a
        # bare `<select>` with no label of any kind, so every translatable field
        # of the ballot editor is preceded by an unnamed combobox.
        describe "#secure_elections_language_selector_label" do
          subject(:markup) { helper.secure_elections_language_selector_label("some-field-tabs", "Question title") }

          before do
            allow(helper).to receive(:current_locale).and_return("en")
            allow(helper).to receive(:available_locales).and_return(locales)
          end

          context "when core renders the switcher as a select" do
            let(:locales) { %w(en ca es fr de) }

            it "names it after the field it switches" do
              expect(markup).to include('for="some-field-tabs"')
              expect(markup).to include("Translation language for: Question title")
            end

            it "is for a screen reader only — the select is already visible" do
              expect(markup).to include('class="sr-only"')
            end
          end

          context "when core renders language tabs instead" do
            let(:locales) { %w(en ca es) }

            it "renders nothing, since the id would point at a list" do
              expect(markup).to be_nil
            end
          end
        end

        # The link an organiser copies out of the admin panel and puts in an
        # email. It is the same link the public Vote button follows, minus the
        # exit — there is no election page behind an email to go back to.
        describe "#secure_elections_direct_voting_url" do
          subject(:url) { helper.secure_elections_direct_voting_url(election) }

          let(:election) { create(:vocdoni_election, :on_chain, component:) }

          it "is absolute, because it is going into somebody else's inbox" do
            expect(url).to start_with("http://test.host#{Decidim::SecureElections::Engine::VOTE_PATH}?v=")
          end

          it "opens this election, with no way back and no credential" do
            fields = Decidim::SecureElections::VotingPageUrl.decode(URI.parse(url).query.delete_prefix("v="))

            expect(fields[:process]).to eq(election.vocdoni_process_id)
            expect(fields[:api]).to eq(Decidim::SecureElections.api_url)
            expect(fields[:exit]).to be_nil
            expect(url).not_to include("vsk_")
          end

          context "when the election is not on chain yet" do
            let(:election) { create(:vocdoni_election, :ready_to_publish, component:) }

            it "is nil, so the panel offers only the public page" do
              expect(url).to be_nil
            end
          end
        end
      end
    end
  end
end
