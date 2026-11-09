# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Compares what the chain holds for an external-CSP process with what
      # Decidim derived from its own root. It reads the Vochain API directly,
      # never the SaaS, which it does not trust for this. Signing starts only
      # once `verify_roots!` has marked the process `verified`.
      #
      # A mismatch in anything the chain makes immutable (census root, origin,
      # dynamic census) or in what proves the election is ours (anonymous
      # off, organization, chain id, a production-safe root) marks the process
      # `compromised` for good. A chain census size below the confirmed size
      # only means a resize has not mined yet: it logs a warning and enqueues
      # {ResizeCensusJob}. Chain errors are transient {ApiError}s and leave
      # `csp_state` as it was, so the next sync tick retries.
      class CspVerifier
        # Chain statuses (`models.ProcessStatus` names) of an election that
        # still accepts votes and so needs census room.
        OPEN_CHAIN_STATUSES = %w(READY PAUSED).freeze

        attr_reader :process, :chain

        def initialize(process, chain: ChainClient.new)
          @process = process
          @chain = chain
        end

        def verify_roots!
          raise Csp::Compromised, "process #{process.id} is compromised" if process.csp_state == "compromised"

          elections = csp_elections!
          info = chain.chain_info.to_h
          raise_compromised!("chain_id") if process.chain_id.present? && info["chainId"] != process.chain_id
          begin
            Vocdoni.csp_keyring.assert_prod_safe!(info["chainId"])
          rescue Csp::ConfigurationError
            raise_compromised!("root_denied")
          end

          chain_elections = elections.map do |ce|
            e = chain.election(ce.upstream_id).to_h
            checks = immutable_checks(ce, e).merge(
              anonymous: e.dig("voteMode", "anonymous") == false,
              org: same_hex?(e["organizationId"], Vocdoni.org_address)
            )
            failed = checks.reject { |_, ok| ok }.keys
            raise_compromised!(failed.join(",")) if failed.any?

            e
          end

          process.update!(csp_state: "verified", csp_verified_at: Time.current)
          check_sizes(chain_elections)
        end

        # Runs on every sync tick of a verified process. Only what the chain
        # makes immutable can flag it.
        def recheck!
          chain_elections = csp_elections!.map do |ce|
            e = chain.election(ce.upstream_id).to_h
            failed = immutable_checks(ce, e).reject { |_, ok| ok }.keys
            raise_compromised!(failed.join(",")) if failed.any?

            e
          end
          check_sizes(chain_elections)
        end

        private

        # Every Decidim question must have its row and its on-chain id before
        # anything can be compared; until then the chain is not ready.
        def csp_elections!
          elections = process.csp_elections.order(:decidim_question_id).to_a
          raise Csp::IntegrityError, "process #{process.id} has no csp elections" if elections.empty?
          raise ApiError.new("csp elections of process #{process.id} are not on chain yet", transient: true) if elections.any? { |ce| ce.upstream_id.blank? }

          elections
        end

        def immutable_checks(csp_election, chain_election)
          { root: chain_election.dig("census", "censusRoot").to_s.delete_prefix("0x").downcase == csp_election.census_root,
            origin: chain_election.dig("census", "censusOrigin") == Vocdoni.csp_origin,
            dynamic: chain_election.dig("electionMode", "dynamicCensus") == false }
        end

        # A chain size below census_size means a resize has not mined yet; it is
        # never a compromise. Elections that no longer take votes need no room.
        def check_sizes(chain_elections)
          sizes = chain_elections.select { |e| OPEN_CHAIN_STATUSES.include?(e["status"].to_s.upcase) }
                                 .map { |e| e.dig("census", "maxCensusSize").to_i }
          chain_size = sizes.min
          return if chain_size.nil? || chain_size >= process.census_size.to_i

          Rails.logger.warn({ event: "csp.size_behind", process_id: process.id, chain_size:, census_size: process.census_size }.to_json)
          return unless Rails.cache.write("vocdoni/csp/resize/#{process.id}", 1, expires_in: 1.minute, unless_exist: true)

          ResizeCensusJob.perform_later(process.id)
        end

        def same_hex?(left, right)
          a = left.to_s.sub(/\A0x/i, "")
          b = right.to_s.sub(/\A0x/i, "")
          a.present? && a.casecmp?(b)
        end

        # Marks the process compromised, tells the admin (last_error) which
        # checks failed, and raises. Names checks only, never key material.
        def raise_compromised!(failed)
          process.csp_state = "compromised"
          process.record_failure!("CSP verification failed (#{failed}): end this election",
                                  step: "verify_roots", code: "csp_compromised", state: nil)
          Rails.logger.error({ event: "csp.compromised", process_id: process.id, csp_root_id: process.csp_root_id, failed: }.to_json)
          raise Csp::Compromised, "process #{process.id} failed the chain checks: #{failed}"
        end
      end
    end
  end
end
