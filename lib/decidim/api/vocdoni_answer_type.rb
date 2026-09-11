# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    # An answer (a choice) of a Vocdoni question.
    #
    # `value` is the 0-based integer actually encoded in the ballot, so it is
    # what a tally read from the chain is keyed by.
    class VocdoniAnswerType < Decidim::Api::Types::BaseObject
      description "An answer of a Vocdoni question"

      implements Decidim::Core::TimestampsInterface

      field :id, GraphQL::Types::ID, "The internal ID of this answer", null: false
      field :position, GraphQL::Types::Int, "Order of this answer within the question", null: true
      field :title, Decidim::Core::TranslatedFieldType, "The title of this answer", null: false
      field :value, GraphQL::Types::Int, "The 0-based choice value encoded in the ballot", null: false
      field :votes_count, GraphQL::Types::Int, "How many votes this answer received", null: false
      field :votes_percent,
            GraphQL::Types::Float,
            "Share of this question's ballots that picked this answer, as a percentage",
            null: false

      def votes_percent
        object.votes_percent.round(2)
      end
    end
  end
end
end
