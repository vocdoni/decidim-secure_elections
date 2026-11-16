# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe ExplorerLinks do
        subject(:links) { described_class.for(election) }

        let(:election) { create(:election, :published, :ongoing, :with_internal_users_census) }
        let!(:first_question) { create(:election_question, :with_response_options, election:) }
        let!(:second_question) { create(:election_question, :with_response_options, election:) }

        before { allow(Vocdoni).to receive(:explorer_url).and_return("https://stg.explorer.vote/") }

        context "when the election is not on Vocdoni" do
          it { is_expected.to be_empty }
        end

        context "when the process is not published yet" do
          before { create(:vocdoni_process, :publishing, election:) }

          it { is_expected.to be_empty }
        end

        context "when the process is published" do
          before do
            create(:vocdoni_process, :published, election:, metadata: {
                     "questions" => [
                       { "decidim_question_id" => first_question.id, "vocdoni_upstream_id" => "0xABCDEF01" },
                       { "decidim_question_id" => second_question.id, "vocdoni_upstream_id" => "c0ffee02" }
                     ]
                   })
          end

          it "links each question to its election on the explorer" do
            expect(links.map(&:question)).to eq([first_question, second_question])
            expect(links.map(&:url)).to eq(%w(
                                             https://stg.explorer.vote/process/abcdef01
                                             https://stg.explorer.vote/process/c0ffee02
                                           ))
          end
        end

        context "when a question has no on-chain election" do
          before do
            create(:vocdoni_process, :published, election:, metadata: {
                     "questions" => [
                       { "decidim_question_id" => first_question.id, "vocdoni_upstream_id" => nil },
                       { "decidim_question_id" => second_question.id, "vocdoni_upstream_id" => "c0ffee02" }
                     ]
                   })
          end

          it "skips it" do
            expect(links.map(&:question)).to eq([second_question])
          end
        end
      end

      describe ".explorer_election_url" do
        before { allow(Vocdoni).to receive(:explorer_url).and_return("https://dev.explorer.vote") }

        it "is nil for a blank id" do
          expect(Vocdoni.explorer_election_url(nil)).to be_nil
          expect(Vocdoni.explorer_election_url(" ")).to be_nil
        end

        it "builds the explorer's process path with bare lowercase hex" do
          expect(Vocdoni.explorer_election_url("0xC0FFEE")).to eq("https://dev.explorer.vote/process/c0ffee")
        end
      end
    end
  end
end
