# frozen_string_literal: true

require "spec_helper"
require "rake"

describe "decidim_elections_vocdoni results recovery tasks" do
  let(:api_url) { "https://saas-api.example.org" }
  let(:process_id) { "6885f0c2c1a4e2f0b1d33a01" }
  let(:election) { create(:election, results_availability: "after_end") }
  let!(:question) do
    create(:election_question, election:, question_type: "multiple_option").tap do |q|
      create_list(:election_response_option, 2, question: q)
    end
  end
  let!(:vocdoni_process) do
    create(:vocdoni_process, :published,
           vocdoni_process_id: process_id, election:,
           metadata: { "questions" => [{ "decidim_question_id" => question.id, "vocdoni_question_id" => "q-1" }] })
  end

  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)
    unless Rake::Task.task_defined?("decidim_elections_vocdoni:resync_results")
      Rake.load_rakefile(Decidim::Elections::Vocdoni::Engine.root.join("lib/tasks/decidim_elections_vocdoni.rake").to_s)
    end
  end

  def run_task(name, *)
    task = Rake::Task[name]
    task.reenable
    task.invoke(*)
  end

  # What the results job left behind before multiple-option matrices were
  # mapped: the question's vote count, but zero on every option.
  before { question.update_columns(votes_count: 1) } # rubocop:disable Rails/SkipsModelValidations

  it "lists an election whose multiple-option counts were never written" do
    expect { run_task("decidim_elections_vocdoni:find_unsynced_results") }
      .to output(/election ##{election.id} \(after_end\): question\(s\) #{question.id}/).to_stdout
  end

  it "rewrites the counts from the chain tally" do
    stub_request(:get, "#{api_url}/processes/#{process_id}/results")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: {
        "questions" => [{ "questionId" => "q-1", "voteCount" => 1, "finalResults" => true, "results" => [%w(0 1), %w(1 0)] }]
      }.to_json)

    expect { run_task("decidim_elections_vocdoni:resync_results", election.id.to_s) }.to output(/After:/).to_stdout

    expect(question.response_options.order(:id).pluck(:votes_count)).to eq([1, 0])
    expect { run_task("decidim_elections_vocdoni:find_unsynced_results") }
      .to output(/No multiple-option question/).to_stdout
  end
end
