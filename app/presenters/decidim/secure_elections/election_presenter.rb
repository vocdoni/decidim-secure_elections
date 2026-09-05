# frozen_string_literal: true

module Decidim
  module SecureElections
    # Renders the attributes of an election. Everything it exposes is a local
    # read; it never touches the Vocdoni API and it never exposes any credential.
    class ElectionPresenter < Decidim::ResourcePresenter
      include Decidim::ResourceHelper

      def election
        __getobj__
      end

      def title(html_escape: false, all_locales: false)
        return unless election

        super(election.title, html_escape, all_locales)
      end

      def description(all_locales: false)
        return unless election

        editor_locales(election.description, all_locales)
      end

      def election_path
        return nil unless election

        Decidim::ResourceLocatorPresenter.new(election).path
      end

      # A safe, credential-free summary of the election status. Used by the
      # admin monitor and by the public status endpoint.
      def status_summary
        {
          id: election.id,
          status: election.status,
          on_chain: election.on_chain?,
          start_at: election.start_at&.iso8601,
          end_at: election.end_at&.iso8601,
          census_size: election.census_size,
          votes_count: election.votes_count,
          turnout: election.turnout,
          results_synced_at: election.results_synced_at&.iso8601
        }
      end
    end
  end
end
