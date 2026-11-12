# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Registers the `vocdoni` voting backend with the client-side booth of
      # `decidim-elections`. The booth renders Decidim's own question, confirm
      # and receipt screens; `public/vocdoni/booth-adapter.js` authenticates
      # against the Vocdoni CSP and casts from the browser.
      module VotingBackend
        ADAPTER_SCRIPT = "/vocdoni/booth-adapter.js"

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
            manifest.client_script = ADAPTER_SCRIPT
            manifest.pre_ballot_partial = "decidim/elections/vocdoni/booth/otp_panel"
            manifest.receipt_partial = "decidim/elections/vocdoni/booth/receipt_note"
            manifest.vote_overwrite = false
            manifest.supports_per_question = true

            manifest.applies_to { |election| enabled? && election.vocdoni_process.present? }
            manifest.booth_config { |election, voter_uid:, **| booth_config(election, voter_uid:) }
            # The CSP's `check` is authoritative, in the browser.
            manifest.voted { |_election, _voter_uid| false }
            manifest.csp_directives { |_election| { "connect-src" => [Vocdoni.api_url.to_s.sub(%r{/+\z}, "")] } }
          end
        end

        # `voter_uid` is what the election's census minted for this session:
        # a signed-in participant for `internal_users`, a CSV row for
        # `token_csv` (whose voters need not have a Decidim account).
        def self.booth_config(election, voter_uid:)
          process = election.vocdoni_process
          subject = VoterCredential.subject_for(election, voter_uid)
          email = CensusMember.email(subject)
          phone = CensusMember.phone(subject) if process.metadata.to_h.dig("settings", "twofa_fields").to_a.include?("phone")
          meta = process.questions_metadata.index_by { |row| row["decidim_question_id"].to_i }
          ready = process.published? && process.vocdoni_process_id.present?

          config = {
            apiUrl: Vocdoni.api_url,
            processId: ready ? process.vocdoni_process_id : nil,
            chainId: process.chain_id,
            explorerUrl: Vocdoni.explorer_url,
            castNotificationUrl: Decidim::EngineRouter.main_proxy(election.component).election_vocdoni_cast_notification_path(election),
            credentials: { memberNumber: VoterCredential.for(election, subject) },
            contact: { email:, phone:, masked: mask(email) }.compact,
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
            i18n: I18n.t("decidim.elections.vocdoni.votes.page").slice(:status, :errors, :otp, :blocked, :receipt).merge(
              not_ready: I18n.t("decidim.elections.vocdoni.booth.launcher.not_ready",
                                default: "This election is not yet ready to accept votes on the blockchain. Please try again in a few moments.")
            )
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

        def self.mask(email)
          return nil if email.blank?

          local, domain = email.split("@", 2)
          "#{local[0]}•••@#{domain}"
        end
      end
    end
  end
end
