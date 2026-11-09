# frozen_string_literal: true

require "spec_helper"

describe Decidim::Elections::Vocdoni::PublishElectionJob do
  subject(:job) { described_class.new }

  let(:process) { create(:vocdoni_process, census_mode: "attested") }
  let(:election) { process.election }

  before do
    job.instance_variable_set(:@election, election)
    job.instance_variable_set(:@process, process)
    allow(election).to receive(:census).and_return(double(count: 10))
  end

  it "adopts the configured census mode for a process not created yet" do
    process.update!(census_mode: "memberbase")
    allow(Decidim::Elections::Vocdoni).to receive(:census_mode).and_return("attested")

    job.send(:adopt_census_mode!)
    expect(process.reload).to be_attested
  end

  it "keeps the mode of a process already created on the SaaS" do
    process.update!(census_mode: "memberbase", vocdoni_process_id: "6885f0c2c1a4e2f0b1d33a01")
    allow(Decidim::Elections::Vocdoni).to receive(:census_mode).and_return("attested")

    job.send(:adopt_census_mode!)
    expect(process.reload).not_to be_attested
  end

  it "declares the signer and ceil(eligible × 1.2) instead of a roster" do
    job.send(:prepare_census!)

    expect(job.send(:census_payload)).to eq(
      "attested" => { "signer" => process.signer_address, "maxCensusSize" => 12 },
      "twoFaFields" => []
    )
  end

  it "refuses a 2FA channel the gem cannot attest" do
    process.update!(metadata: { "settings" => { "twofa_fields" => ["phone"] } })

    expect { job.send(:prepare_census!) }.to raise_error(Decidim::Elections::Vocdoni::ApiError, /email 2FA only/)
  end
end
