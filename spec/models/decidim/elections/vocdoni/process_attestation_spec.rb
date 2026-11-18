# frozen_string_literal: true

require "spec_helper"

describe Decidim::Elections::Vocdoni::Process do
  subject(:process) { create(:vocdoni_process, :published) }

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
    other = create(:vocdoni_process, :published, vocdoni_process_id: "6885f0c2c1a4e2f0b1d33a02")
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
    expect(process.metadata).not_to have_key(described_class::PENDING_SIGNER_KEY)
  end

  it "keeps the registered candidate across a crash and switches to it on the retry" do
    before = process.signer_address
    registered = []
    crashing = described_class.find(process.id)
    allow(crashing).to receive(:update!).and_call_original
    allow(crashing).to receive(:update!).with(hash_including(:attestation_signer_key)).and_raise(Timeout::Error)
    expect { crashing.rotate_attestation_signer! { |address| registered << address } }.to raise_error(Timeout::Error)

    reloaded = described_class.find(process.id)
    expect(reloaded.signer_address).to eq(before)
    expect(reloaded.metadata[described_class::PENDING_SIGNER_KEY]).to be_present

    rotated = reloaded.rotate_attestation_signer! { |address| registered << address }
    expect(registered.uniq).to eq([rotated])
    expect(process.reload.signer_address).to eq(rotated)
    expect(process.metadata).not_to have_key(described_class::PENDING_SIGNER_KEY)
  end

  it "keeps signing with the old key while the SaaS is unreachable" do
    before = process.signer_address
    expect do
      process.rotate_attestation_signer! { raise Decidim::Elections::Vocdoni::ApiError.new("timeout", status: 503) }
    end.to raise_error(Decidim::Elections::Vocdoni::ApiError)

    expect(process.reload.signer_address).to eq(before)
    expect(process.metadata).to have_key(described_class::PENDING_SIGNER_KEY)
  end

  it "drops the candidate the SaaS rejects" do
    before = process.signer_address
    expect do
      process.rotate_attestation_signer! { raise Decidim::Elections::Vocdoni::ApiError.new("bad signer", status: 400) }
    end.to raise_error(Decidim::Elections::Vocdoni::ApiError)

    expect(process.reload.signer_address).to eq(before)
    expect(process.metadata).not_to have_key(described_class::PENDING_SIGNER_KEY)
  end

  it "counts one row per attested voterId" do
    process.record_issued_attestation!("0xaa")
    process.record_issued_attestation!("0xaa")
    process.record_issued_attestation!("0xbb")

    expect(process.issued_attestations.count).to eq(2)
    expect(process.issued_attestations.find_by(voter_id: "0xaa").issued_count).to eq(2)
  end

  it "counts up to the cap and no further" do
    expect(Array.new(3) { process.record_issued_attestation!("0xaa", cap: 2) }).to eq([true, true, false])
    expect(process.issued_attestations.find_by(voter_id: "0xaa").issued_count).to eq(2)
  end

  describe ".attested_census_size" do
    it "declares ceil(eligible × 1.2), at least 1" do
      expect([0, 1, 3, 10, 11].map { |eligible| described_class.attested_census_size(eligible) }).to eq([1, 2, 4, 12, 14])
    end
  end

  describe "#two_fa_fields" do
    it "reads the Security tab's choice" do
      process.update!(metadata: { "settings" => { "twofa_fields" => ["email"] } })
      expect(process.two_fa_fields).to eq(["email"])
    end

    it "is empty without a choice" do
      expect(process.two_fa_fields).to eq([])
    end
  end
end
