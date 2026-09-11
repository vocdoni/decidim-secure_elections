# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    # A question of a Vocdoni election.
    #
    # Each question is its own Vochain election (ARCHITECTURE §1), which is why
    # `upstreamId` is exposed: it is the identifier a third party needs to
    # recompute this question's tally from the chain.
    class VocdoniQuestionType < Decidim::Api::Types::BaseObject
      description "A question of a Vocdoni election"

      implements Decidim::Core::TimestampsInterface

      field :answers,
            [Decidim::Elections::Vocdoni::VocdoniAnswerType, { null: true }],
            "The answers a voter can choose from",
            null: false
      field :description, Decidim::Core::TranslatedFieldType, "The description of this question", null: true
      field :id, GraphQL::Types::ID, "The internal ID of this question", null: false
      field :max_choices, GraphQL::Types::Int, "Maximum number of answers a voter may pick, on multiple choice questions", null: true
      field :min_choices, GraphQL::Types::Int, "Minimum number of answers a voter must pick, on multiple choice questions", null: true
      field :position, GraphQL::Types::Int, "Order of this question within the election", null: true
      field :question_id,
            GraphQL::Types::String,
            "The id of this question inside the Vocdoni process",
            method: :vocdoni_question_id,
            null: true
      field :question_type, GraphQL::Types::String, "Either singlechoice or multichoice", null: false
      field :secret_until_the_end,
            GraphQL::Types::Boolean,
            "Whether the ballots for this question stay encrypted until the election ends",
            null: false
      field :status, GraphQL::Types::String, "The lifecycle status of this question on chain", method: :vocdoni_status, null: true
      field :title, Decidim::Core::TranslatedFieldType, "The title of this question", null: false
      field :upstream_id,
            GraphQL::Types::String,
            "The Vochain election id this question's votes were cast against",
            method: :vocdoni_upstream_id,
            null: true
      field :votes_count, GraphQL::Types::Int, "How many ballots were cast for this question", null: false
    end
  end
end
end
