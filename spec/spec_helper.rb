# frozen_string_literal: true

require "decidim/dev"

ENV["ENGINE_ROOT"] = File.dirname(__dir__)

Decidim::Dev.dummy_app_path = File.expand_path(File.join(__dir__, "decidim_dummy_app"))

require "decidim/dev/test/base_spec_helper"
require "webmock/rspec"

# Every spec in this module must be hermetic: the Vocdoni SaaS API is never
# contacted from the test suite. Anything that reaches the network is a bug in
# the test, so block it outright rather than letting it hang on a real socket.
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.configure do |config|
  # Give the module a known-good configuration by default so specs do not each
  # have to stub `Decidim::Elections::Vocdoni` settings. Individual specs override as needed.
  config.before do
    allow(Decidim::Elections::Vocdoni).to receive_messages(
      api_url: "https://saas-api.example.org",
      api_key: "vsk_test_key",
      org_address: "0x0000000000000000000000000000000000000001"
    )
  end
end

require_relative "factories"

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }
