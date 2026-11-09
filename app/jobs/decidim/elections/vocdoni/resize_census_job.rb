# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Raises the census size declared on chain when the roster of an
      # external-CSP process outgrows it, to ceil(roster × (1 + headroom)).
      # Enqueued by the sign endpoint, by the chain checks of
      # {CspVerifier} and by the admin, at most once a minute per process.
      #
      # Idempotent: it reads the chain first and only asks the SaaS for more
      # room when the open elections lack it. `census_size` is the size
      # Decidim has seen on chain; it changes only here and at publish, and it
      # never shrinks, because the target is never below it and the chain only
      # accepts increases.
      class ResizeCensusJob < ApplicationJob
        queue_as :vocdoni

        # SaaS code of a 402 on a managed organization whose integrator wallet
        # cannot pay the census growth.
        INSUFFICIENT_WALLET_BALANCE = 40_175

        retry_on Decidim::Elections::Vocdoni::ApiError, wait: :polynomially_longer, attempts: 5 do |job, error|
          Process.find_by(id: job.arguments.first)&.record_failure!(
            "census resize failed: #{job.send(:redact, error.message)}", step: "resize", state: nil
          )
        end

        def perform(process_id)
          @process = Process.find_by(id: process_id)
          return if process.nil?

          @election = process.election
          return if process.vocdoni_process_id.blank? || !process.csp_elections.exists?

          current = chain_size
          return if current.nil? # no election takes votes any more

          roster = election.census.count(election).to_i
          target = roster > process.census_size.to_i ? Vocdoni.declared_census_size(election, roster) : process.census_size.to_i
          return confirm_on_chain!(target, current) if current >= target

          response = request_size!(target)
          return if response.nil? # reported to the admin; retrying would not pay

          await_job!(response["jobId"]) # raises on a failed or timed-out SaaS job; a blank id has nothing to await
          confirm_on_chain!(target)
        end

        private

        attr_reader :process

        # Records what the chain holds once it covers the target; until then
        # the transient error makes `retry_on` try again with backoff.
        def confirm_on_chain!(target, current = chain_size)
          raise ApiError.new("census resize of process #{process.id} not on chain yet (#{current.inspect} < #{target})", transient: true) if current.nil? || current < target

          process.update!(census_size: current) if current > process.census_size.to_i
        end

        # The smallest maxCensusSize over the elections still taking votes, as
        # the chain reports it; nil when none is open.
        def chain_size
          sizes = process.csp_elections.where.not(upstream_id: nil).filter_map do |ce|
            e = chain.election(ce.upstream_id).to_h
            next unless CspVerifier::OPEN_CHAIN_STATUSES.include?(e["status"].to_s.upcase)

            e.dig("census", "maxCensusSize").to_i
          end
          sizes.min
        end

        # A 402 means the process has not paid for that many voters. A managed
        # organization pays from its integrator wallet through the census
        # checkout, then the size is asked again once.
        def request_size!(target)
          client.elections.external_csp_size(process.vocdoni_process_id, target).to_h
        rescue ApiError => e
          raise unless e.status == 402
          return nil unless pay_for_growth!(target)

          client.elections.external_csp_size(process.vocdoni_process_id, target).to_h
        end

        # True when the wallet was debited. A short wallet, or a Stripe session
        # a person would have to complete, leaves census_size unchanged and is
        # reported to the admin instead of retried.
        def pay_for_growth!(target)
          checkout = client.elections.census_checkout(process.vocdoni_process_id, census_size: target, return_url: admin_url).to_h
          return true if checkout["sessionId"].blank?

          process.record_failure!("census growth needs payment", step: "resize", state: nil)
          false
        rescue ApiError => e
          raise unless e.code == INSUFFICIENT_WALLET_BALANCE

          process.record_failure!("integrator wallet short", step: "resize", state: nil, code: e.code)
          false
        end

        def admin_url
          Decidim::EngineRouter.admin_proxy(election.component).dashboard_election_url(election, host: election.organization.host)
        end

        def chain
          @chain ||= ChainClient.new
        end
      end
    end
  end
end
