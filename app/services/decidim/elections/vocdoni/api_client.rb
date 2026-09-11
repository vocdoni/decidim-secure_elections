# frozen_string_literal: true

require "faraday"
require "faraday/retry"

module Decidim
  module Elections
    module Vocdoni
    # HTTP client for the Vocdoni SaaS REST API (the "Integrator SDK" surface),
    # mirroring the JS SDK's shape: `#elections`, `#organizations`, `#census`
    # and `#jobs`.
    #
    # Everything this class does is *organiser* work: creating a process,
    # publishing it, moving question status, reading tallies. It never handles a
    # ballot — the voter's browser talks to the same API on its own.
    #
    # Two connections are kept:
    #
    # * an **authenticated** one, carrying the integrator API key as a Bearer
    #   token. Building it goes through {Decidim::Elections::Vocdoni.validate_configuration!}
    #   so a misconfigured deployment fails loudly instead of silently talking
    #   to the wrong chain.
    # * a **token-less** one for the public reads (`GET /processes/{id}` and
    #   `GET /processes/{id}/results`), which must work with no API key at all.
    #
    # Every non-2xx response is turned into a {Decidim::Elections::Vocdoni::ApiError}
    # carrying the HTTP status, the API's numeric `code` and the parsed body.
    #
    # @example Reading a published process without any credential
    #   Decidim::Elections::Vocdoni::ApiClient.new(api_url: "https://saas-api-stg.vocdoni.net")
    #                              .elections.get(process_id, authenticated: false)
    #
    # @example Creating and publishing a process
    #   client = Decidim::Elections::Vocdoni::ApiClient.new
    #   process = client.elections.create(title: "Board election", questions: [...])
    #   job = client.elections.publish(process["processId"])
    #   client.jobs.wait_for(job["jobId"])
    class ApiClient
      # Timestamps the API accepts, e.g. `2026-07-29T14:51:08Z`.
      TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%SZ"

      # Transient upstream failures worth another attempt on an idempotent read.
      RETRY_STATUSES = [429, 500, 502, 503, 504].freeze

      # Retries are deliberately restricted to GET: `POST /processes` or
      # `POST /processes/{id}/publish` are *not* idempotent and a blind retry
      # would create a duplicate process or a duplicate on-chain transaction.
      #
      # `Faraday::RetriableResponse` has to stay in `exceptions`: it is what
      # faraday-retry raises internally for a `retry_statuses` hit, so
      # overriding the list without it silently disables status-based retries
      # and leaks the exception out of the middleware.
      RETRY_OPTIONS = {
        max: 2,
        interval: 0.5,
        interval_randomness: 0.5,
        backoff_factor: 2,
        methods: [:get],
        retry_statuses: RETRY_STATUSES,
        exceptions: [
          Faraday::RetriableResponse,
          Faraday::TimeoutError,
          Faraday::ConnectionFailed,
          Errno::ETIMEDOUT
        ]
      }.freeze

      # Authentication modes understood by {#request}:
      #
      # * `:required` — validates the configuration and sends the API key.
      # * `:optional` — sends the API key when there is one (so that an admin
      #   can read a draft), falls back to an anonymous read otherwise.
      # * `:none` — never sends the API key.
      AUTH_MODES = [:required, :optional, :none].freeze

      USER_AGENT = "decidim-elections-vocdoni/#{Decidim::Elections::Vocdoni::VERSION}".freeze

      attr_reader :api_url, :timeout, :open_timeout, :default_locale

      # The integrator key is readable, because two connections and the job
      # layer's redaction need it — but only from inside. A public reader would
      # put `vsk_…` in full into anything that calls `#inspect` on a client: a
      # Rails error page listing local variables, a console session, an
      # exception tracker serialising the frame it crashed in.
      #
      # `inspect` is overridden for the same reason. Ruby's default prints every
      # instance variable, so it would leak the key even with the reader gone.
      def inspect
        "#<#{self.class.name} api_url=#{api_url.inspect} authenticated=#{api_key.present?}>"
      end
      alias to_s inspect

      # @param api_url [String, nil] base URL of the SaaS API. Defaults to
      #   `Decidim::Elections::Vocdoni.api_url`.
      # @param api_key [String, nil] integrator API key (`vsk_…`). Defaults to
      #   `Decidim::Elections::Vocdoni.api_key`; a blank value falls back to the
      #   configuration. To read without any credential, use the public reads
      #   (`elections.get(id, authenticated: false)`), which never touch the
      #   authenticated connection.
      # @param timeout [Integer, nil] read timeout in seconds. Defaults to
      #   `Decidim::Elections::Vocdoni.timeout`.
      # @param open_timeout [Integer, nil] connect timeout in seconds. Defaults
      #   to `Decidim::Elections::Vocdoni.open_timeout`.
      # @param default_locale [String, Symbol, nil] locale used as the
      #   `"default"` entry of the API's language maps — pass the
      #   organization's `default_locale`. Falls back to `Decidim.default_locale`.
      def initialize(api_url: nil, api_key: nil, timeout: nil, open_timeout: nil, default_locale: nil)
        @api_url = api_url.presence || Decidim::Elections::Vocdoni.api_url
        @api_key = api_key.presence || Decidim::Elections::Vocdoni.api_key
        @timeout = timeout || Decidim::Elections::Vocdoni.timeout
        @open_timeout = open_timeout || Decidim::Elections::Vocdoni.open_timeout
        @default_locale = default_locale
      end

      # Processes (what Decidim calls elections).
      #
      # @return [Decidim::Elections::Vocdoni::ApiClient::Elections]
      def elections
        @elections ||= Elections.new(self)
      end

      # Organizations, their memberbase and their member groups.
      #
      # @return [Decidim::Elections::Vocdoni::ApiClient::Organizations]
      def organizations
        @organizations ||= Organizations.new(self)
      end

      # Org-level censuses. A *process* census is inline in the create payload,
      # but the member group it points at has to be materialized as a CSP
      # census first — that is what these routes do (ARCHITECTURE §4c).
      #
      # @return [Decidim::Elections::Vocdoni::ApiClient::Census]
      def census
        @census ||= Census.new(self)
      end

      # Async jobs returned by publish, status changes and the vote relay.
      #
      # @return [Decidim::Elections::Vocdoni::ApiClient::Jobs]
      def jobs
        @jobs ||= Jobs.new(self)
      end

      # Turns a plain string or a Decidim translated hash into the language map
      # the API demands. See {Decidim::Elections::Vocdoni::ApiClient::Localizable.localize}.
      #
      # @param value [String, Hash, nil]
      # @return [Hash{String => String}, nil]
      def localize(value)
        Localizable.localize(value, default_locale:)
      end

      # Performs a `GET`.
      #
      # @param path [String] path relative to the API root, e.g. `/processes/1`.
      # @param params [Hash, nil] query string parameters.
      # @param auth [Symbol] one of {AUTH_MODES}.
      # @return [Hash, Array, String] the parsed response body.
      # @raise [Decidim::Elections::Vocdoni::ApiError] on any non-2xx response.
      def get(path, params: nil, auth: :required)
        request(:get, path, params:, auth:)
      end

      # Performs a `POST`.
      #
      # @param path [String] path relative to the API root.
      # @param body [Hash, Array, nil] request body, serialized as JSON.
      # @param params [Hash, nil] query string parameters.
      # @param auth [Symbol] one of {AUTH_MODES}.
      # @return [Hash, Array, String] the parsed response body.
      # @raise [Decidim::Elections::Vocdoni::ApiError] on any non-2xx response.
      def post(path, body: nil, params: nil, auth: :required)
        request(:post, path, body:, params:, auth:)
      end

      # Performs a `PUT`.
      #
      # @param path [String] path relative to the API root.
      # @param body [Hash, Array, nil] request body, serialized as JSON.
      # @param params [Hash, nil] query string parameters.
      # @param auth [Symbol] one of {AUTH_MODES}.
      # @return [Hash, Array, String] the parsed response body.
      # @raise [Decidim::Elections::Vocdoni::ApiError] on any non-2xx response.
      def put(path, body: nil, params: nil, auth: :required)
        request(:put, path, body:, params:, auth:)
      end

      # Performs a `DELETE`.
      #
      # @param path [String] path relative to the API root.
      # @param params [Hash, nil] query string parameters.
      # @param auth [Symbol] one of {AUTH_MODES}.
      # @return [Hash, Array, String] the parsed response body.
      # @raise [Decidim::Elections::Vocdoni::ApiError] on any non-2xx response.
      def delete(path, params: nil, auth: :required)
        request(:delete, path, params:, auth:)
      end

      # Issues a single HTTP request and maps the response.
      #
      # @param method [Symbol] `:get`, `:post`, `:put` or `:delete`.
      # @param path [String] path relative to the API root.
      # @param params [Hash, nil] query string parameters.
      # @param body [Hash, Array, nil] request body, serialized as JSON.
      # @param auth [Symbol] one of {AUTH_MODES}.
      # @return [Hash, Array, String] the parsed response body.
      # @raise [Decidim::Elections::Vocdoni::ApiError] on a non-2xx response, a timeout or
      #   a connection failure.
      # @raise [Decidim::Elections::Vocdoni::ConfigurationError] when the module is not
      #   configured well enough for the requested auth mode.
      def request(method, path, params: nil, body: nil, auth: :required)
        response = connection_for(auth).public_send(method) do |req|
          req.url(relative_path(path))
          req.params.update(params.transform_keys(&:to_s)) if params.present?
          req.body = body unless body.nil?
        end

        handle(response)
      rescue Faraday::Error => e
        raise Decidim::Elections::Vocdoni::ApiError.new(
          "Vocdoni API #{method.to_s.upcase} #{path} failed: #{e.class} #{e.message}",
          status: e.respond_to?(:response_status) ? e.response_status : nil
        )
      end

      # Connection carrying the integrator API key.
      #
      # @return [Faraday::Connection]
      def authenticated_connection
        @authenticated_connection ||= build_connection(token: api_key)
      end

      # Token-less connection used by the public reads.
      #
      # @return [Faraday::Connection]
      def public_connection
        @public_connection ||= build_connection(token: nil)
      end

      private

      attr_reader :api_key

      # @param auth [Symbol] one of {AUTH_MODES}
      # @return [Faraday::Connection]
      def connection_for(auth)
        case auth
        when :required
          Decidim::Elections::Vocdoni.validate_configuration!
          authenticated_connection
        when :optional
          api_key.present? ? authenticated_connection : public_connection
        when :none
          public_connection
        else
          raise ArgumentError, "Unknown auth mode #{auth.inspect}, expected one of #{AUTH_MODES.inspect}"
        end
      end

      # @param token [String, nil] Bearer token, or nil for an anonymous connection
      # @return [Faraday::Connection]
      def build_connection(token:)
        raise Decidim::Elections::Vocdoni::ConfigurationError, "decidim-elections-vocdoni is not configured. Missing: api_url (VOCDONI_API_URL)" if api_url.blank?

        Faraday.new(url: base_url) do |conn|
          # Outermost so that a retried request replays the whole stack.
          conn.request :retry, RETRY_OPTIONS
          conn.request :json
          conn.response :json, content_type: /\bjson$/

          conn.headers["Accept"] = "application/json"
          conn.headers["User-Agent"] = USER_AGENT
          conn.headers["Authorization"] = "Bearer #{token}" if token.present?

          conn.options.timeout = timeout
          conn.options.open_timeout = open_timeout

          conn.adapter Faraday.default_adapter
        end
      end

      # Base URL with a trailing slash so that any path prefix in the
      # configured URL survives the join.
      #
      # @return [String]
      def base_url
        "#{api_url.to_s.chomp("/")}/"
      end

      # Faraday resets the whole path when given an absolute one, which would
      # drop a configured path prefix.
      #
      # @param path [String]
      # @return [String]
      def relative_path(path)
        path.to_s.delete_prefix("/")
      end

      # @param response [Faraday::Response]
      # @return [Hash, Array, String]
      # @raise [Decidim::Elections::Vocdoni::ApiError]
      def handle(response)
        body = normalize_body(response.body)
        return body if response.success?

        raise Decidim::Elections::Vocdoni::ApiError.new(
          error_message(response, body),
          status: response.status,
          code: error_code(body),
          body:
        )
      end

      # JSON objects already come back with string keys; this only guards
      # against an adapter or a stub handing us symbols, and turns "no content"
      # into an empty hash.
      #
      # @param body [Object]
      # @return [Hash, Array, String]
      def normalize_body(body)
        case body
        when nil
          {}
        when Hash
          body.deep_stringify_keys
        when Array
          body.map { |item| item.is_a?(Hash) ? item.deep_stringify_keys : item }
        when String
          body.strip.empty? ? {} : body
        else
          body
        end
      end

      # The API reports failures as `{"error": "…", "code": 40004}`.
      #
      # @param body [Object] the parsed response body
      # @return [Integer, nil]
      def error_code(body)
        return nil unless body.is_a?(Hash)

        code = body["code"]
        code.is_a?(Numeric) ? code.to_i : nil
      end

      # @param response [Faraday::Response]
      # @param body [Object] the parsed response body
      # @return [String]
      def error_message(response, body)
        detail = body.is_a?(Hash) ? (body["error"].presence || body["message"].presence) : body.presence
        code = error_code(body)

        message = "Vocdoni API #{response.env.method.to_s.upcase} #{response.env.url} failed with HTTP #{response.status}"
        message << " (code #{code})" if code
        message << ": #{detail}" if detail.present?
        message
      end
    end
  end
end
end
