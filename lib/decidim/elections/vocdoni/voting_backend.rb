# frozen_string_literal: true

require "digest"

module Decidim
  module Elections
    module Vocdoni
      # Registers the `vocdoni` voting backend with the client-side booth of
      # `decidim-elections`. The booth renders Decidim's own question, confirm
      # and receipt screens; `public/vocdoni/booth-adapter.js` authenticates
      # against the Vocdoni CSP and casts from the browser.
      module VotingBackend
        ADAPTER_PATH = "/vocdoni/booth-adapter.js"

        # Adapter URL with a content digest, so browsers and CDNs that cache the
        # fixed path (Cloudflare applies a 4 h browser TTL) fetch the new bundle
        # as soon as a deploy changes it.
        def self.adapter_script
          @adapter_script ||= begin
            file = Engine.root.join("public", ADAPTER_PATH.delete_prefix("/"))
            file.file? ? "#{ADAPTER_PATH}?v=#{Digest::SHA256.file(file).hexdigest[0, 12]}" : ADAPTER_PATH
          end
        end

        def self.available?
          Decidim::Elections.respond_to?(:voting_backends)
        end

        # Rollback switch: VOCDONI_INTEGRATED_BOOTH=false restores the static booth.
        def self.enabled?
          available? && ENV.fetch("VOCDONI_INTEGRATED_BOOTH", "true") != "false"
        end

        def self.active_for?(election)
          enabled? && election.voting_backend.name == :vocdoni
        end

        def self.register!
          return unless available?
          return if Decidim::Elections.voting_backends.find(:vocdoni)

          Decidim::Elections.voting_backends.register(:vocdoni) do |manifest|
            manifest.transport = :client
            manifest.client_adapter = "vocdoni"
            manifest.client_script = adapter_script
            manifest.pre_ballot_partial = "decidim/elections/vocdoni/booth/otp_panel"
            manifest.receipt_partial = "decidim/elections/vocdoni/booth/receipt_note"
            manifest.vote_overwrite = false
            manifest.supports_per_question = true
            # Opt out of live tally; the fork adds this attribute conditionally.
            manifest.live_tally = false if manifest.respond_to?(:live_tally=)

            manifest.applies_to { |election| enabled? && election.vocdoni_process.present? }
            manifest.booth_config { |election, voter_uid:, **| booth_config(election, voter_uid:) }
            # The CSP's `check` is authoritative, in the browser.
            manifest.voted { |_election, _voter_uid| false }
            manifest.csp_directives { |_election| { "connect-src" => [Vocdoni.api_url.to_s.sub(%r{/+\z}, "")] } }
          end
        end

        # `voter_uid` is what the election's census minted for this session: a participant for
        # `internal_users`, a CSV row for `token_csv`. The booth authenticates them with the
        # attestation it fetches from attestationUrl; the one-time code goes to their contact.
        def self.booth_config(election, voter_uid:)
          process = election.vocdoni_process
          router = Decidim::EngineRouter.main_proxy(election.component)
          kind = process.contact_kind
          meta = process.questions_metadata.index_by { |row| row["decidim_question_id"].to_i }
          ready = process.published? && process.vocdoni_process_id.present?

          config = {
            apiUrl: Vocdoni.api_url,
            processId: ready ? process.vocdoni_process_id : nil,
            chainId: process.chain_id,
            explorerUrl: Vocdoni.explorer_url,
            castNotificationUrl: router.election_vocdoni_cast_notification_path(election),
            attestationUrl: router.election_vocdoni_attestation_path(election),
            contact: kind ? { channel: kind, masked: mask(kind, VoterAttestation.contact(election, voter_uid, kind)) }.compact : {},
            questions: booth_questions(election).map do |question|
              row = meta[question.id] || {}
              {
                questionId: question.id.to_s,
                title: question.body.to_h[I18n.locale.to_s].presence || question.body.to_h.values.grep(String).first.to_s,
                vocdoniQuestionId: row["vocdoni_question_id"],
                upstreamId: row["vocdoni_upstream_id"],
                choices: question.response_options.order(:id).each_with_index.to_h { |option, idx| [option.id.to_s, idx] }
              }
            end,
            i18n: booth_i18n(kind)
          }
          config.merge!(per_question_config(election)) if election.per_question?
          config
        end

        # A per-question booth only offers the questions the admin has opened
        # and not yet closed; the others are still paused (or ended) on chain.
        def self.booth_questions(election)
          election.per_question? ? election.questions.enabled.unpublished_results : election.questions
        end

        # The adapter polls `waitingUrl` after the voter is done with the open
        # questions and adds the next one to the booth when the admin opens it.
        def self.per_question_config(election)
          router = Decidim::EngineRouter.main_proxy(election.component)
          {
            perQuestion: true,
            waitingUrl: router.waiting_election_per_question_votes_path(election_id: election.id, format: :json),
            perQuestionI18n: I18n.t("decidim.elections.vocdoni.booth.per_question")
          }
        end

        def self.booth_i18n(kind)
          i18n = I18n.t("decidim.elections.vocdoni.votes.page").slice(:status, :errors, :otp, :blocked, :receipt)
          i18n[:errors] = i18n[:errors].merge(no_contact: I18n.t("decidim.elections.vocdoni.booth.no_contact.#{kind}")) if kind
          i18n.merge(
            not_ready: I18n.t("decidim.elections.vocdoni.booth.launcher.not_ready",
                              default: "This election is not yet ready to accept votes on the blockchain. Please try again in a few moments.")
          )
        end

        # What the one-time code panel shows of the contact: "a•••@example.org", "+•••••••••56".
        def self.mask(kind, contact)
          return nil if contact.blank?
          return "+#{"•" * (contact.length - 3)}#{contact[-2..]}" if kind == "phone"

          local, domain = contact.split("@", 2)
          "#{local[0]}•••@#{domain}"
        end
      end
    end
  end
end
