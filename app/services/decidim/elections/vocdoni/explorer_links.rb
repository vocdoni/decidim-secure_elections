# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Explorer links of a Decidim election: one per question, as each
      # question is published as an election of its own on chain. Empty until
      # the election is published there.
      class ExplorerLinks
        Link = Data.define(:question, :url)

        def self.for(election) = new(election).links

        def initialize(election)
          @election = election
        end

        def links
          process = @election.vocdoni_process
          return [] unless process&.published?

          questions = @election.questions.index_by(&:id)
          process.questions_metadata.filter_map do |entry|
            question = questions[entry["decidim_question_id"]]
            url = Vocdoni.explorer_election_url(entry["vocdoni_upstream_id"])
            Link.new(question:, url:) if question && url
          end
        end
      end
    end
  end
end
