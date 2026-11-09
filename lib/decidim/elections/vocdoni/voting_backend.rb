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
            manifest.receipt_partial = "decidim/elections/vocdoni/booth/receipt_note"
            manifest.vote_overwrite = false
            manifest.supports_per_question = true

            manifest.applies_to { |election| enabled? && election.vocdoni_process.present? }
            manifest.booth_config { |election, _voter_uid:, _current_user:| booth_config(election) }
            # The CSP's `check` is authoritative, in the browser.
            manifest.voted do |election, voter_uid|
              questions = election.available_questions.to_a
              next false if voter_uid.blank? || questions.empty?

              secret = begin
                Vocdoni.csp_pin_secret
              rescue Csp::RootMissing
                next false
              end

              process = election.vocdoni_process
              next false if process.nil?

              digest = secret.digest(Csp::PinSecret.voter_key(election, voter_uid))
              questions.all? do |question|
                CspPin.confirmed.exists?(decidim_question_id: question.id, voter_digest: digest)
              end
            end
            manifest.csp_directives { |_election| {} }
          end
        end

        def self.booth_config(election)
          process = election.vocdoni_process
          meta = process.questions_metadata.index_by { |row| row["decidim_question_id"].to_i }
          ready = process.published? && process.vocdoni_process_id.present?
          proxy = Decidim::EngineRouter.main_proxy(election.component)

          {
            apiUrl: Vocdoni.api_url,
            processId: ready ? process.vocdoni_process_id : nil,
            chainId: process.chain_id,
            explorerUrl: Vocdoni.explorer_url,
            signUrl: proxy.election_csp_sign_path(election),
            statusUrl: proxy.election_csp_status_path(election),
            confirmUrl: proxy.election_csp_confirm_path(election),
            proofType: "ECDSA",
            perQuestion: election.per_question?,
            questions: election.questions.map do |question|
              row = meta[question.id] || {}
              {
                questionId: question.id.to_s,
                title: question.body.to_h[I18n.locale.to_s].presence || question.body.to_h.values.grep(String).first.to_s,
                vocdoniQuestionId: row["vocdoni_question_id"],
                upstreamId: row["vocdoni_upstream_id"],
                choices: question.response_options.order(:id).each_with_index.to_h { |option, idx| [option.id.to_s, idx] }
              }
            end,
            i18n: I18n.t("decidim.elections.vocdoni.votes.page").slice(:status, :errors, :blocked, :receipt).merge(
              not_ready: I18n.t("decidim.elections.vocdoni.booth.launcher.not_ready",
                                default: "This election is not yet ready to accept votes on the blockchain. Please try again in a few moments.")
            )
          }
        end
      end
    end
  end
end
