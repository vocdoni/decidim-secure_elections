# frozen_string_literal: true

require "spec_helper"
require "json"

describe Decidim::Elections::Vocdoni::Attestation do
  subject(:attestation) { described_class }

  # exported by saas-backend `go test ./csp/attestation/ -update`
  let(:vectors) { JSON.parse(File.read(File.expand_path("../../../../fixtures/attestation_vectors.json", __dir__))) }
  let(:priv) { attestation.b2i(attestation.hex_to_bytes(vectors["privateKey"])) }
  let(:contract) { attestation.hex_to_bytes(vectors["verifyingContract"]) }

  def bytes(hex) = attestation.hex_to_bytes(hex)

  def fields(vector)
    {
      process_id: bytes(vector["processId"]),
      voter_id: bytes(vector["voterId"]),
      contact_hash: bytes(vector["contactHash"]),
      expires_at: vector["expiresAt"]
    }
  end

  it "derives the signer address" do
    expect(attestation.address(priv)).to eq(bytes(vectors["signer"]))
  end

  it "computes the domain separator of the SaaS" do
    expect(attestation.domain_separator(contract)).to eq(bytes(vectors["domainSeparator"]))
  end

  it "reproduces every vector byte for byte" do
    expect(vectors["cases"].size).to eq(4)
    vectors["cases"].each do |vector|
      if vector["kind"].to_s.empty?
        expect(bytes(vector["contactHash"])).to eq("\x00".b * 32)
      else
        expect(attestation.contact_hash(bytes(vector["salt"]), vector["kind"], vector["contact"]))
          .to eq(bytes(vector["contactHash"])), vector["name"]
      end
      expect(attestation.struct_hash(**fields(vector))).to eq(bytes(vector["structHash"])), vector["name"]
      digest = attestation.digest(contract, **fields(vector))
      expect(digest).to eq(bytes(vector["digest"])), vector["name"]
      expect(attestation.sign(priv, digest)).to eq(bytes(vector["signature"])), vector["name"]
    end
  end

  it "signs low-s with v 27 or 28 and recovers the signer" do
    digest = attestation.keccak("any digest")
    sig = attestation.sign(priv, digest)
    expect(attestation.b2i(sig[32, 32])).to be <= described_class::N / 2
    expect(sig[64].ord).to be_between(27, 28)
    expect(attestation.recover(digest, sig)).to eq(attestation.address(priv))
  end

  it "canonicalizes an email the way the SaaS checks it" do
    expect(attestation.canonical_email("  Voter@Example.ORG ")).to eq("voter@example.org")
  end

  it "refuses malformed input" do
    expect { attestation.contact_hash("short", "email", "a@b.org") }.to raise_error(ArgumentError)
    expect { attestation.contact_hash("\x00".b * 32, "sms", "a@b.org") }.to raise_error(ArgumentError)
    expect { attestation.struct_hash(**fields(vectors["cases"].first), process_id: "\x00".b * 32) }
      .to raise_error(ArgumentError)
    expect { attestation.sign(0, "\x00".b * 32) }.to raise_error(ArgumentError)
  end
end
