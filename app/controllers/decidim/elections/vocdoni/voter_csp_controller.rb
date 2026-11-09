# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Decidim as the CSP of an external-CSP process: signs each eligible
      # voter's ephemeral address, once per question, with the per-question key
      # derived from the root the process was published with.
      #
      # A voter gets one pin per question, bound to the first address they ask
      # for. The same address is re-signed (RFC 6979 yields the same signature);
      # any other address is refused, so a voter can never hold two valid
      # signatures for one question. The database enforces the same invariant
      # (unique indexes and an append-only trigger on the pins table).
      #
      # CSRF is required on every request (inherited from
      # `Decidim::ApplicationController`); the booth sends the meta tag token.
      # Log lines carry a voter digest prefix, never an address, a nullifier or
      # a signature.
      class VoterCspController < Decidim::Elections::ApplicationController
        include Decidim::Elections::UsesCensusAccess

        SIGN_LIMIT = 3
        READ_LIMIT = 30
        RECHECK_INTERVAL = 30.seconds

        rescue_from Csp::Error, Csp::ConfigurationError do |error|
          csp_failure(error.code, error)
        end

        before_action :require_process

        # GET …/csp/status: per question, whether this voter can sign and what
        # they are pinned to.
        def status
          return render_error(:forbidden, "not_in_census") if voter_uid.blank?
          return render_error(:too_many_requests, "rate_limited") unless throttle?("status", nil, READ_LIMIT)

          render json: { questions: csp_elections.map { |csp_election| status_for(csp_election) } }
        end

        # POST …/csp/sign {questionId, address}
        def sign
          # Roots, pin secret and the pins trigger are checked before any digest.
          Vocdoni.csp_ready!
          return render_error(:forbidden, "not_allowed") unless allowed_to?(:create, :vote, election:)
          return render_error(:forbidden, "not_in_census") if voter_uid.blank?

          csp_election = signable_csp_election(params.require(:questionId))
          return render_error(:conflict, "question_closed") unless csp_election

          address = parse_address(params.require(:address))
          return render_error(:unprocessable_content, "invalid_address") unless address
          return render_error(:too_many_requests, "rate_limited") unless throttle?("sign", csp_election.decidim_question_id, SIGN_LIMIT)

          root = signing_root!
          pin = find_pin(csp_election)
          return answer_pin(pin, address, csp_election, root) if pin
          return answer_signature(csp_election, address, root, "issued") if create_pin(csp_election, address)

          # Lost the insert: either this voter pinned concurrently, or another
          # voter holds the address on this question.
          pin = find_pin(csp_election)
          return answer_pin(pin, address, csp_election, root) if pin

          log_sign(csp_election, "address_taken")
          render_error(:conflict, "address_taken")
        end

        # POST …/csp/confirm {questionId}: records that the pinned address voted,
        # once the chain has the vote.
        def confirm
          return render_error(:forbidden, "not_in_census") if voter_uid.blank?
          return render_error(:too_many_requests, "rate_limited") unless throttle?("confirm", nil, READ_LIMIT)

          csp_election = vocdoni_process.csp_elections.find_by(decidim_question_id: params.require(:questionId).to_i)
          return render_error(:not_found, "question_not_found") unless csp_election

          pin = find_pin(csp_election)
          return render_error(:not_found, "pin_not_found") unless pin&.address

          confirm_vote!(pin) if pin.vote_confirmed_at.nil? && chain.vote(pin.nullifier)
          render json: status_for(csp_election, pin:, recheck: false)
        rescue ApiError
          render_error(:service_unavailable, "chain_unavailable")
        end

        private

        def require_process
          render_error(:not_found, "not_found") if vocdoni_process.nil?
        end

        def render_error(status, code) = render(json: { error: code }, status:)

        # 500 plus an error-level log naming the process and its root id, never
        # key material.
        def csp_failure(code, error)
          Rails.logger.error({ event: "csp.failure", code:, process_id: vocdoni_process&.id, csp_root_id: vocdoni_process&.csp_root_id,
                               error: error.class.name }.to_json)
          render_error(:internal_server_error, code)
        end

        def create_pin(csp_election, address)
          created = nil
          CspPin.transaction do
            # Serialises new pins and the roster check per process.
            Process.lock.find(vocdoni_process.id)
            enqueue_resize_if_grown
            begin
              CspPin.transaction(requires_new: true) do
                created = CspPin.create!(process: vocdoni_process, decidim_question_id: csp_election.decidim_question_id, election_id: election.id,
                                         csp_root_id: vocdoni_process.csp_root_id, seed: csp_election.seed, voter_digest: digest,
                                         address: address.unpack1("H*"),
                                         nullifier: Csp::Crypto.nullifier(address, [csp_election.upstream_id].pack("H*")).unpack1("H*"))
              end
            rescue ActiveRecord::RecordNotUnique
              created = nil
            end
          end
          created
        end

        def answer_pin(pin, address, csp_election, root)
          if pin.address.nil? || pin.address != address.unpack1("H*")
            log_sign(csp_election, "address_pinned")
            return render_error(:conflict, "address_pinned")
          end
          answer_signature(csp_election, address, root, "resigned")
        end

        def answer_signature(csp_election, address, root, outcome)
          key = Csp::Crypto.election_key(root, csp_election.seed_bytes)
          raise Csp::Error, "root mismatch" unless Csp::Crypto.public_key(key).unpack1("H*") == csp_election.census_root

          bundle = Csp::Crypto.ca_bundle([csp_election.upstream_id].pack("H*"), address)
          signature = Csp::Crypto.sign_eth(key, bundle)
          log_sign(csp_election, outcome)
          render json: { signature: signature.unpack1("H*"), weight: "01", proofType: "ECDSA" }
        end

        # The question's CSP election when this voter may be signed for it now:
        # the process roots are verified, the election is ongoing, the chain
        # election is READY and, for per-question elections, the question is
        # open.
        def signable_csp_election(question_id)
          return nil unless vocdoni_process.csp_verified? && election.ongoing?

          csp_election = vocdoni_process.csp_elections.find_by(decidim_question_id: question_id.to_i)
          return nil unless csp_election

          question = election.questions.find_by(id: csp_election.decidim_question_id)
          return nil unless question && chain_ready?(csp_election, question)
          return nil if election.per_question? && !question.voting_enabled?

          csp_election
        end

        # The chain election exists (upstream id) and the last sync saw it READY.
        def chain_ready?(csp_election, question)
          meta = vocdoni_process.questions_metadata.find { |m| m["decidim_question_id"].to_i == question.id }
          meta.present? && meta["vocdoni_status"].to_s.upcase == "READY" && csp_election.upstream_id.present?
        end

        # `{questionId, votingEnabled, canVote, pinnedAddress, nullifier, hasVoted}`.
        # An unconfirmed pin with an address is checked against the chain at
        # most once per RECHECK_INTERVAL.
        def status_for(csp_election, pin: pins_by_question[csp_election.decidim_question_id], recheck: true)
          recheck_vote(pin) if recheck && pin&.address && pin.vote_confirmed_at.nil?
          enabled = signable_csp_election(csp_election.decidim_question_id).present?
          {
            questionId: csp_election.decidim_question_id,
            votingEnabled: enabled,
            canVote: enabled && (pin.nil? || pin.address.present?),
            pinnedAddress: pin&.address && "0x#{pin.address}",
            nullifier: pin&.nullifier,
            hasVoted: pin&.vote_confirmed_at.present? || false
          }
        end

        def recheck_vote(pin)
          return unless Rails.cache.write("vocdoni/csp/recheck/#{pin.id}", 1, expires_in: RECHECK_INTERVAL, unless_exist: true)

          confirm_vote!(pin) if chain.vote(pin.nullifier)
        rescue ApiError => e
          Rails.logger.warn({ event: "csp.recheck", process_id: vocdoni_process.id, question_id: pin.decidim_question_id,
                              error: e.class.name }.to_json)
        end

        # Sets the confirmation only if it is still unset: the trigger refuses
        # to change it once set, and two confirms may race.
        def confirm_vote!(pin)
          now = Time.current
          CspPin.where(id: pin.id, vote_confirmed_at: nil).update_all(vote_confirmed_at: now, updated_at: now) # rubocop:disable Rails/SkipsModelValidations
          pin.reload
        end

        def csp_elections = vocdoni_process.csp_elections.order(:decidim_question_id)

        def pins_by_question
          @pins_by_question ||= CspPin.where(decidim_question_id: csp_elections.select(:decidim_question_id), voter_digest: digest)
                                      .index_by(&:decidim_question_id)
        end

        def find_pin(csp_election) = CspPin.find_by(decidim_question_id: csp_election.decidim_question_id, voter_digest: digest)

        # HMAC of the election-scoped voter key under the pin secret. A missing
        # pin secret raises Csp::RootMissing (`csp_root_missing`).
        def digest
          @digest ||= Vocdoni.csp_pin_secret.digest(Csp::PinSecret.voter_key(election, voter_uid))
        end

        # Not `process`, which is AbstractController's dispatch entry point.
        def vocdoni_process = @vocdoni_process ||= election.vocdoni_process

        def chain = @chain ||= ChainClient.new

        def parse_address(hex) = hex.to_s.match?(/\A0x\h{40}\z/) ? [hex[2..].downcase].pack("H*") : nil

        # The root the process was published with, never another one.
        def signing_root!
          raise Csp::PinSecretMismatch, "pin secret differs from the process" unless vocdoni_process.pin_secret_id == Vocdoni.csp_pin_secret.id

          Vocdoni.csp_keyring.fetch(vocdoni_process.csp_root_id)
        end

        def enqueue_resize_if_grown
          roster = election.census.count(election)
          return if roster <= vocdoni_process.census_size.to_i
          return unless Rails.cache.write("vocdoni/csp/resize/#{vocdoni_process.id}", 1, expires_in: 1.minute, unless_exist: true)

          ResizeCensusJob.perform_later(vocdoni_process.id)
        end

        # Counter per (voter digest, question) in Rails.cache, 60 s window.
        def throttle?(kind, question_id, limit)
          key = "vocdoni/csp/#{kind}/#{digest}/#{question_id}"
          count = Rails.cache.increment(key, 1, expires_in: 1.minute) || (Rails.cache.write(key, 1, expires_in: 1.minute) && 1)
          count <= limit
        end

        def log_sign(csp_election, outcome)
          Rails.logger.info({ event: "csp.sign", process_id: vocdoni_process.id, question_id: csp_election.decidim_question_id,
                              voter_digest: digest[0, 16], outcome: }.to_json)
        end
      end
    end
  end
end
