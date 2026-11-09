# frozen_string_literal: true

# WebMock stubs of the Vochain API (`GET /chain/info`, `GET /elections/{id}`)
# as vocdoni-node answers them: hex without `0x`, `voteMode`/`electionMode`
# with every field present (protojson EmitUnpopulated).
module CspChainSpecHelpers
  CSP_CHAIN_URL = "https://chain.example.org/v2"
  CSP_ORG_HEX = "0000000000000000000000000000000000000001"

  def csp_chain_url = CSP_CHAIN_URL

  def csp_org_hex = CSP_ORG_HEX

  def json_response(body, status: 200)
    { status:, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end

  def stub_chain_info(chain_id = "vocdoni/DEV/36")
    stub_request(:get, "#{CSP_CHAIN_URL}/chain/info").to_return(json_response({ chainId: chain_id }))
  end

  CHAIN_ELECTION_DEFAULTS = { origin: "OFF_CHAIN_CA_V2", max_census_size: 12, dynamic_census: false, anonymous: false,
                              organization_id: CSP_ORG_HEX, status: "READY" }.freeze

  # A chain election that matches the csp election; override the census
  # root or any field of CHAIN_ELECTION_DEFAULTS.
  def chain_election(csp_election, **overrides)
    o = CHAIN_ELECTION_DEFAULTS.merge(census_root: csp_election.census_root).merge(overrides)
    {
      electionId: csp_election.upstream_id,
      organizationId: o[:organization_id],
      status: o[:status],
      census: { censusOrigin: o[:origin], censusRoot: o[:census_root], censusURL: "https://decidim.example.org", maxCensusSize: o[:max_census_size] },
      voteMode: { serial: false, anonymous: o[:anonymous], encryptedVotes: false, uniqueValues: false, costFromWeight: false },
      electionMode: { autoStart: true, interruptible: true, dynamicCensus: o[:dynamic_census], encryptedMetaData: false, preRegister: false }
    }
  end

  # Each extra body is answered by a later request, in order.
  def stub_chain_election(upstream_id, body, *later)
    stub = stub_request(:get, "#{CSP_CHAIN_URL}/elections/#{upstream_id}").to_return(json_response(body))
    later.each { |next_body| stub = stub.then.to_return(json_response(next_body)) }
    stub
  end

  # Sets the CSP variables for the example and forgets the memoized CSP state.
  def use_csp_env(vars)
    %w(VOCDONI_CSP_ROOTS VOCDONI_CSP_PIN_SECRET).each { |k| ENV.delete(k) }
    vars.each { |k, v| ENV[k] = v }
    Decidim::Elections::Vocdoni.reset_csp!
  end
end

# A fresh CSP root and pin secret in ENV and the chain API at CSP_CHAIN_URL.
RSpec.shared_context "with a csp root and chain" do
  let(:csp_root) { Decidim::Elections::Vocdoni::Csp::Crypto.i2b(SecureRandom.random_number(Decidim::Elections::Vocdoni::Csp::Crypto::N - 1) + 1) }
  let(:csp_root_id) { Decidim::Elections::Vocdoni::Csp::Keyring.id_for(csp_root) }
  let(:csp_pin_secret_hex) { SecureRandom.hex(32) }
  let(:csp_pin_secret_id) { Decidim::Elections::Vocdoni::Csp::PinSecret.new([csp_pin_secret_hex].pack("H*")).id }
  let(:csp_env) { { "VOCDONI_CSP_ROOTS" => "#{csp_root_id}:#{csp_root.unpack1("H*")}", "VOCDONI_CSP_PIN_SECRET" => csp_pin_secret_hex } }

  around do |example|
    old = %w(VOCDONI_CSP_ROOTS VOCDONI_CSP_PIN_SECRET).index_with { |k| ENV.fetch(k, nil) }
    example.run
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
    Decidim::Elections::Vocdoni.reset_csp!
  end

  before do
    use_csp_env(csp_env)
    allow(Decidim::Elections::Vocdoni).to receive(:chain_api_url).and_return(CspChainSpecHelpers::CSP_CHAIN_URL)
  end

  def derived_census_root(seed)
    crypto = Decidim::Elections::Vocdoni::Csp::Crypto
    crypto.public_key(crypto.election_key(csp_root, [seed].pack("H*"))).unpack1("H*")
  end
end

RSpec.configure do |config|
  config.include CspChainSpecHelpers
end
