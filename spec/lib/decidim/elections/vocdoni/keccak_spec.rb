# frozen_string_literal: true

require "spec_helper"

describe Decidim::Elections::Vocdoni::Keccak do
  def hex(bytes) = bytes.unpack1("H*")

  it "matches the known Keccak-256 vectors" do
    expect(hex(described_class.digest(""))).to eq("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    expect(hex(described_class.digest("abc"))).to eq("4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
    expect(hex(described_class.digest("The quick brown fox jumps over the lazy dog")))
      .to eq("4d741b6f1eb29cb2a9b9911c82f56fa8d73b04959d3d9d222895df6c0b28aa15")
  end

  # 135 and 136 bytes put the padding in one block or spill it into the next.
  it "matches OpenSSL's KECCAK-256 across block boundaries" do
    skip "OpenSSL lacks KECCAK-256" unless Decidim::Elections::Vocdoni::Attestation::OPENSSL_KECCAK

    [0, 1, 135, 136, 137, 272, 1000].each do |size|
      message = Random.new(size).bytes(size)
      expect(described_class.digest(message)).to eq(OpenSSL::Digest.new("KECCAK-256").digest(message)), size.to_s
    end
  end
end
