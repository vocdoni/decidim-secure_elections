# frozen_string_literal: true

module Decidim
  module SecureElections
    module Admin
      # Brings the local copy of an on-chain election up to date.
      #
      # Two things can be out of date, and which one it is is not the admin's
      # problem to diagnose:
      #
      # * the publication never finished — the process exists upstream but its
      #   ids or its chain id were never read back. `PublishElectionJob` is
      #   idempotent and resumes exactly where it stopped.
      # * the tally is stale — `SyncResultsJob` refills `results_cache`.
      #
      # Broadcasts `:ok` with `:publish` or `:results` so the UI can say which
      # one it started.
      class RefreshElection < Decidim::Command
        def initialize(election)
          @election = election
        end

        def call
          return broadcast(:invalid) unless election.on_chain? || election.publishing?

          if publication_incomplete?
            Decidim::SecureElections::PublishElectionJob.perform_later(election.id)
            broadcast(:ok, :publish)
          else
            Decidim::SecureElections::SyncResultsJob.perform_later(election.id)
            broadcast(:ok, :results)
          end
        end

        private

        attr_reader :election

        # A process that exists upstream but never reached a live status, or
        # whose questions have no Vochain election id yet, cannot be voted on.
        # A `publishing?` election that never even reached the chain — the job
        # died before persisting the process id — is also incomplete: resuming
        # picks up wherever the previous run stopped.
        def publication_incomplete?
          return true if election.publishing? && !election.on_chain?
          return true unless Decidim::SecureElections::Election::LIVE_STATUSES.include?(election.status) ||
                             %w(ended results canceled).include?(election.status)

          election.questions.exists?(vocdoni_upstream_id: nil)
        end
      end
    end
  end
end
