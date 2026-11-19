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

  def expect_every_vector
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

  it "reproduces every vector byte for byte" do
    expect_every_vector
  end

  # GitHub's runners and older images ship OpenSSL < 3.2, so the pure-Ruby Keccak must give the
  # same bytes, type hashes included.
  context "without OpenSSL's KECCAK-256" do
    before { stub_const("Decidim::Elections::Vocdoni::Attestation::OPENSSL_KECCAK", false) }

    it "reproduces every vector byte for byte" do
      expect(Decidim::Elections::Vocdoni::Keccak).to receive(:digest).at_least(:once).and_call_original
      expect(attestation.keccak("EIP712Domain(string name,string version,address verifyingContract)"))
        .to eq(described_class::DOMAIN_TYPEHASH)
      expect(attestation.keccak("Attestation(bytes12 processId,bytes32 voterId,bytes32 contactHash,uint64 expiresAt)"))
        .to eq(described_class::ATTESTATION_TYPEHASH)
      expect(attestation.address(priv)).to eq(bytes(vectors["signer"]))
      expect(attestation.domain_separator(contract)).to eq(bytes(vectors["domainSeparator"]))
      expect_every_vector
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

  describe ".canonical_phone" do
    it "writes an international number in E.164" do
      {
        "+34600123456" => "+34600123456",
        " +34 600 12 34 56 " => "+34600123456",
        "+34-600.123/456" => "+34600123456",
        "0034 600 123 456" => "+34600123456",
        "+44 (0)20 7946 0018" => "+442079460018",
        "+1 (415) 555-0100" => "+14155550100",
        "＋３４ ６００ １２３ ４５６" => "+34600123456",
        "+34\u00a0600\u00a0123\u00a0456" => "+34600123456"
      }.each { |raw, canonical| expect(attestation.canonical_phone(raw)).to eq(canonical), raw }
    end

    it "refuses a number without a country code or outside E.164" do
      [nil, "", "600123456", "0600123456", "+0600123456", "+34 600 123 456 789 012", "+34", "+34 600 ABC 456", "tel:+34600123456"]
        .each { |raw| expect(attestation.canonical_phone(raw)).to be_nil, raw.inspect }
    end

    # The SaaS vector's contactHash opens with the phone however the census wrote it.
    it "matches the SaaS phone vector from a formatted number" do
      vector = vectors["cases"].find { |entry| entry["kind"] == "phone" }
      contact = attestation.canonical_phone("+34 600 12 34 56")

      expect(contact).to eq(vector["contact"])
      expect(attestation.contact_hash(bytes(vector["salt"]), "phone", contact)).to eq(bytes(vector["contactHash"]))
    end
  end

  it "refuses malformed input" do
    expect { attestation.contact_hash("short", "email", "a@b.org") }.to raise_error(ArgumentError)
    expect { attestation.contact_hash("\x00".b * 32, "sms", "a@b.org") }.to raise_error(ArgumentError)
    expect { attestation.struct_hash(**fields(vectors["cases"].first), process_id: "\x00".b * 32) }
      .to raise_error(ArgumentError)
    expect { attestation.sign(0, "\x00".b * 32) }.to raise_error(ArgumentError)
  end
end
