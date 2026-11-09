# frozen_string_literal: true

require "spec_helper"

describe Decidim::Elections::Vocdoni::Process do
  subject(:process) { create(:vocdoni_process, :published, census_mode: "attested") }

  let(:user) { create(:user, organization: process.election.organization) }

  before { process.ensure_attestation_secrets! }

  it "stores the signer key and the voterId secret encrypted" do
    raw = described_class.connection.select_one(
      "SELECT attestation_signer_key, voter_id_secret FROM decidim_vocdoni_processes WHERE id = #{process.id}"
    )
    expect(raw["attestation_signer_key"]).not_to include(Decidim::Elections::Vocdoni::Attestation.i2b(process.signer_private_key).unpack1("H*"))
    expect(raw["voter_id_secret"]).to be_present
    expect(process.signer_address).to match(/\A0x\h{40}\z/)
  end

  it "draws the secrets once" do
    expect { process.ensure_attestation_secrets! }.not_to(change { process.reload.attestation_signer_key })
  end

  it "derives a stable voterId per voter, distinct per election" do
    other = create(:vocdoni_process, :published, census_mode: "attested", vocdoni_process_id: "6885f0c2c1a4e2f0b1d33a02")
    other.ensure_attestation_secrets!
    uid = user.to_global_id.to_s

    expect(process.reload.voter_id_for(uid)).to eq(described_class.find(process.id).voter_id_for(uid))
    expect(process.voter_id_for(uid).bytesize).to eq(32)
    expect(other.voter_id_for(uid)).not_to eq(process.voter_id_for(uid))
  end

  it "maps census GlobalIDs to voter keys" do
    expect(described_class.voter_key(user.to_global_id.to_s)).to eq("user:#{user.id}")
    expect { described_class.voter_key("gid://app/Decidim::Organization/1") }.to raise_error(ArgumentError)
  end

  it "keeps the old signer when the SaaS refuses the rotation" do
    before = process.signer_address
    expect { process.rotate_attestation_signer! { raise "saas down" } }.to raise_error("saas down")
    expect(process.reload.signer_address).to eq(before)

    rotated = process.rotate_attestation_signer! { |address| expect(address).not_to eq(before) }
    expect(process.reload.signer_address).to eq(rotated)
  end

  it "counts one row per attested voterId" do
    process.record_issued_attestation!("0xaa")
    process.record_issued_attestation!("0xaa")
    process.record_issued_attestation!("0xbb")

    expect(process.issued_attestations.count).to eq(2)
    expect(process.issued_attestations.find_by(voter_id: "0xaa").issued_count).to eq(2)
  end

  it "refuses an unknown census mode" do
    process.census_mode = "other"
    expect(process).not_to be_valid
  end
end
