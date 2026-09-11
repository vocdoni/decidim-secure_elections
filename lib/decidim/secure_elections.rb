# frozen_string_literal: true

require "decidim/secure_elections/version"
require "decidim/secure_elections/admin"
require "decidim/secure_elections/api"
require "decidim/secure_elections/engine"
require "decidim/secure_elections/admin_engine"
require "decidim/secure_elections/component"

# Phase-4 spike (see lib/decidim/secure_elections/phase_4_spike.rb): loaded
# only when PHASE_4_SPIKE=1 is set. Proves the vocdoni/decidim#1 and #2
# extension surface is enough to plug this module in as a decidim-elections
# security layer without patching upstream files. Off by default so
# production paths are unaffected.
require "decidim/secure_elections/phase_4_spike" if ENV["PHASE_4_SPIKE"] == "1"

module Decidim
  # Decidim component that delegates the ballot to the Vocdoni protocol through
  # the Vocdoni SaaS API (the "Integrator SDK" surface).
  #
  # Trust boundary
  # --------------
  # The Rails server holds an integrator API key and performs only *organiser*
  # operations over plain HTTPS: creating a process, publishing it, moving
  # question status, reading tallies. It never sees a ballot.
  #
  # The voter's browser performs the whole voting flow itself against the same
  # public API — CSP auth, ephemeral key generation, ballot encoding and vote
  # signing. No API key is ever sent to the browser, and no ballot ever reaches
  # Decidim. See `app/packs/src/decidim/secure_elections/voter/`.
  #
  # Unlike the previous generation of this module there is **no Node.js runtime
  # on the server** — the SaaS API is reachable from Ruby directly.
  module SecureElections
    # The tables stay `decidim_vocdoni_*` even though the module is
    # `Decidim::SecureElections`.
    #
    # `Rails::Engine.isolate_namespace` derives a table prefix from the engine
    # name and would otherwise expect `decidim_secure_elections_*`. It only does
    # so when the module does not already answer `table_name_prefix`, so
    # defining it here — this file is required before the engine — is what
    # settles it.
    #
    # They stay because `vocdoni` in a column or a table is not this module's
    # name, it is the network the data belongs to: `vocdoni_process_id`,
    # `vocdoni_upstream_id` and `vocdoni_member_id` are identifiers minted by
    # Vocdoni, and renaming the tables around them would buy consistency with
    # the gem's name at the cost of a migration that reads as if the data had
    # changed meaning. The same reasoning keeps the `VOCDONI_*` environment
    # variables and the `:vocdoni` component manifest.
    def self.table_name_prefix = "decidim_vocdoni_"

    # Settings are plain lazy accessors rather than `ActiveSupport::Configurable`
    # for two reasons:
    #
    #   1. `ActiveSupport::Configurable` is deprecated in Rails 8.1 (the Rails
    #      that Decidim 0.33 runs) and is removed in 8.2.
    #   2. Its defaults are evaluated when the gem is *loaded*, which is before
    #      `Rails.application` exists — so reading credentials there raises
    #      `NoMethodError` on nil during boot.
    #
    # Resolving on first read instead means credentials are consulted only once
    # the application is initialized, while still supporting the usual
    # `Decidim::SecureElections.configure { |c| c.api_url = … }` block in an initializer.
    class << self
      attr_writer :api_url, :api_key, :org_address, :explorer_url,
                  :open_timeout, :timeout, :job_timeout

      def configure
        yield self
      end

      # Base URL of the Vocdoni SaaS API.
      #
      # There is deliberately no default. A production deployment that forgets
      # to set this must fail loudly rather than quietly run a real election
      # against a staging chain.
      def api_url
        @api_url ||= ENV.fetch("VOCDONI_API_URL", nil)
      end

      # Integrator API key (`vsk_…`). Server-side only — it is never exposed to
      # the browser, because the voter flow uses only public/CSP-token routes.
      #
      # Rails credentials take precedence so the key need not exist in the
      # environment; ENV remains available for container deployments where no
      # credentials file is mounted.
      def api_key
        @api_key ||= credentials_api_key || ENV.fetch("VOCDONI_API_KEY", nil)
      end

      # Address of the Vocdoni organization owning the processes this Decidim
      # instance creates (`0x…`). Obtained once via
      # `ApiClient#organizations.create_managed`.
      def org_address
        @org_address ||= ENV.fetch("VOCDONI_ORG_ADDRESS", nil)
      end

      # The Vocdoni SaaS bases this module knows, and the explorer that goes
      # with each. `VotingPageUrl::API_HOSTS` and the voting page's own
      # `API_HOSTS` carry the same three bases; this table adds the explorer.
      NETWORKS = {
        "https://saas-api.vocdoni.net" => "https://explorer.vote",
        "https://saas-api-stg.vocdoni.net" => "https://stg.explorer.vote",
        "https://saas-api-dev.vocdoni.net" => "https://dev.explorer.vote"
      }.freeze

      # Public explorer a voter is sent to in order to check their receipt.
      #
      # Derived from `api_url` rather than defaulted to a constant. A fixed
      # default is wrong half the time in a way nobody notices until a voter
      # follows the link: point it at staging and every production receipt leads
      # to an explorer where the vote does not exist; point it at production and
      # every staging receipt does the same. An unrecognised API base falls back
      # to the production explorer, and `VOCDONI_EXPLORER_URL` overrides all of
      # it — which is what a self-hosted network needs.
      def explorer_url
        @explorer_url ||= ENV.fetch("VOCDONI_EXPLORER_URL", nil).presence ||
                          NETWORKS.fetch(api_url.to_s.sub(%r{/+\z}, ""), "https://explorer.vote")
      end

      # HTTP timeouts, in seconds, for calls to the SaaS API.
      def open_timeout
        @open_timeout ||= ENV.fetch("VOCDONI_OPEN_TIMEOUT", "5").to_i
      end

      def timeout
        @timeout ||= ENV.fetch("VOCDONI_TIMEOUT", "30").to_i
      end

      # How long a background job waits for an async SaaS job (publish, status
      # change, vote relay) before giving up.
      def job_timeout
        @job_timeout ||= ENV.fetch("VOCDONI_JOB_TIMEOUT", "120").to_i
      end

      private

      # Credentials are unavailable until the application is initialized, and
      # an app may legitimately have none.
      def credentials_api_key
        return nil unless defined?(Rails) && Rails.respond_to?(:application)
        return nil if Rails.application.nil?

        Rails.application.credentials.dig(:vocdoni, :api_key).presence
      rescue StandardError
        nil
      end
    end

    # True when every setting required to talk to the API is present.
    def self.configured?
      api_url.present? && api_key.present? && org_address.present?
    end

    # Raises unless the module is fully configured. Called by the admin surface
    # so that a misconfiguration surfaces as an actionable message instead of a
    # 500 from the first API call.
    def self.validate_configuration!
      return true if configured?

      missing = {
        "api_url (VOCDONI_API_URL)" => api_url,
        "api_key (credentials vocdoni.api_key / VOCDONI_API_KEY)" => api_key,
        "org_address (VOCDONI_ORG_ADDRESS)" => org_address
      }.select { |_k, v| v.blank? }.keys

      raise Decidim::SecureElections::ConfigurationError,
            "decidim-secure_elections is not configured. Missing: #{missing.join(", ")}"
    end

    # Raised when the module is used without complete configuration.
    class ConfigurationError < StandardError; end

    # Raised for any non-success response from the Vocdoni SaaS API.
    class ApiError < StandardError
      # HTTP status codes worth another attempt on their own: a rate limit or a
      # server-side hiccup that may clear up in a few seconds. Everything else
      # (400, 401, 403, 404, 409, …) is an *answer* — retrying it is guaranteed
      # to fail identically and, when the failing call is `POST /members`, will
      # create fresh orphaned members upstream on every attempt.
      TRANSIENT_STATUSES = [429, 500, 502, 503, 504].freeze

      attr_reader :status, :code, :body

      # @param transient [Boolean, nil] override the inferred verdict. Pass
      #   `false` when the call succeeded at the HTTP level but the *body* is
      #   a permanent rejection (a 2xx that reports `errors` in the payload).
      def initialize(message, status: nil, code: nil, body: nil, transient: nil)
        @status = status
        @code = code
        @body = body
        @transient = transient
        super(message)
      end

      # Whether the caller should try again. A missing status means the request
      # never reached the server (timeout, connection failure) and is worth a
      # retry; a 4xx is a rejection and is not; `transient:` on construction
      # wins over both.
      def transient?
        return @transient unless @transient.nil?

        status.nil? || TRANSIENT_STATUSES.include?(status)
      end
    end

    # Raised when an async SaaS job finishes in a failed state or times out.
    class JobError < ApiError; end
  end
end
