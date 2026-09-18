# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    # Base class for every job that talks to the Vocdoni SaaS API.
    #
    # All API traffic lives here and in its subclasses. Controllers, models,
    # cells, presenters and views must never open a connection — see
    # ARCHITECTURE §0.5.
    class ApplicationJob < Decidim::ApplicationJob
      queue_as :vocdoni

      # A misconfigured instance will not fix itself by retrying.
      discard_on Decidim::Elections::Vocdoni::ConfigurationError

      protected

      # A fresh client per job run. The client reads its credentials from
      # `Decidim::Elections::Vocdoni`; nothing here ever writes to `ENV` (ARCHITECTURE §0.3).
      def client
        @client ||= Decidim::Elections::Vocdoni::ApiClient.new
      end

      # The record the job is working on. Subclasses assign it in `perform` so
      # that the shared helpers can reach it.
      attr_reader :election

      # Waits for an async SaaS job.
      #
      # `wait_for` already raises on a failed job and on a timeout, and it only
      # ever looks at the **top-level** `status` — the nested `result.status`
      # (for example `"READY"`) is the process status, not the job status
      # (ARCHITECTURE §2.2).
      #
      # A publish of an already-published process answers without a `jobId`,
      # which is a success and not something to wait for.
      def await_job!(job_id)
        return nil if job_id.blank?

        client.jobs.wait_for(job_id, timeout: Decidim::Elections::Vocdoni.job_timeout)
      end

      # Turns a Decidim value into the language map the API requires (a bare
      # string is rejected upstream with code 40004, ARCHITECTURE §2.1).
      #
      # The map itself is built by the client; what this adds is stripping the
      # markup first, because on-chain metadata is plain text and a voter would
      # otherwise be shown raw HTML.
      #
      # @param value [String, Hash] a plain string or a Decidim translated hash
      # @return [Hash, nil] a language map with a mandatory "default" entry
      def localize(value)
        Decidim::Elections::Vocdoni::ApiClient::Localizable.localize(
          plain_text_translations(value),
          default_locale:
        )
      end

      def default_locale
        @default_locale ||= (election&.organization&.default_locale || Decidim.default_locale || I18n.default_locale).to_s
      end

      # @param value [String, Hash, nil]
      # @return [String, Hash, nil] the same shape with every leaf stripped
      def plain_text_translations(value)
        return value.to_h.transform_values { |nested| plain_text_translations(nested) } if value.is_a?(Hash)

        plain_text(value)
      end

      # On-chain metadata is plain text; HTML markup would be stored verbatim
      # and shown to voters as markup.
      def plain_text(value)
        return nil if value.nil?

        ActionView::Base.full_sanitizer.sanitize(value.to_s).to_s.squish
      end

      # Records the failure so the admin sees something actionable instead of a
      # silently stuck wizard.
      #
      # ASSUMPTION: the authoritative schema (ARCHITECTURE §4b) has no error
      # column, so the message is kept under a reserved key of `results_cache`
      # rather than adding one.
      #
      # `details` exists because some upstream failures carry the only useful
      # part of the answer in their body rather than in their message — a
      # census validation names the member ids that lack a field, and an admin
      # can act on that list but not on "code 40037". It is stored verbatim so
      # the admin surface can map those ids back onto local records.
      #
      # @param record [ActiveRecord::Base, nil] the election being worked on.
      # @param error [StandardError]
      # @param step [String, Symbol, nil] machine-readable name of the step
      #   that failed, e.g. `"validate_group"`.
      # @param details [Hash, nil] structured, already-safe extra information.
      def record_failure!(record, error, step: nil, details: nil)
        return if record.blank?

        cache = record.results_cache.to_h
        cache["error"] = {
          "message" => redact(error.message),
          "kind" => error.class.name,
          "step" => step.presence&.to_s,
          "code" => error.try(:code),
          "details" => details.presence,
          "at" => Time.current.iso8601
        }.compact
        record.update_columns(results_cache: cache) # rubocop:disable Rails/SkipsModelValidations
      end

      # `results_cache` is rendered in the admin UI, so nothing that smells like
      # a credential may reach it (ARCHITECTURE §0.2).
      def redact(message)
        text = message.to_s
        key = Decidim::Elections::Vocdoni.api_key
        text = text.gsub(key, "[REDACTED]") if key.present?
        text.gsub(/vsk_[A-Za-z0-9._-]+/, "[REDACTED]")
            .gsub(/\bBearer\s+\S+/i, "Bearer [REDACTED]")
      end
    end
  end
end
end
