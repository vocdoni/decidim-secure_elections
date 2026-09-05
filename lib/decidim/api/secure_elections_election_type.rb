# frozen_string_literal: true

module Decidim
  module SecureElections
    # An election run on the Vocdoni protocol.
    #
    # Only public data is exposed. In particular the census configuration
    # (`census_auth_fields`, `census_two_fa_fields`, `census_group_id`) is
    # deliberately absent: it describes how voters are identified, it is
    # organiser-only, and it is of no use to an API consumer. The API also
    # never surfaces anything from `Decidim::SecureElections` configuration.
    class SecureElectionsElectionType < Decidim::Api::Types::BaseObject
      description "A Vocdoni election"

      implements Decidim::Core::TimestampsInterface
      implements Decidim::Core::ReferableInterface

      field :census_size,
            GraphQL::Types::Int,
            "How many people are eligible to vote in this election",
            null: true
      field :chain_id,
            GraphQL::Types::String,
            "The Vocdoni chain this election runs on",
            method: :vocdoni_chain_id,
            null: true
      field :description, Decidim::Core::TranslatedFieldType, "The description of this election", null: true
      field :end_at, Decidim::Core::DateTimeType, "When this election stops accepting votes", null: true
      field :id, GraphQL::Types::ID, "The internal ID of this election", null: false
      field :on_chain,
            GraphQL::Types::Boolean,
            "Whether this election has been written to the blockchain",
            method: :on_chain?,
            null: false
      field :process_id,
            GraphQL::Types::String,
            "The Vocdoni process id of this election, so its result can be verified on chain",
            method: :vocdoni_process_id,
            null: true
      field :published_at, Decidim::Core::DateTimeType, "When this election was published on this website", null: true
      field :questions,
            [Decidim::SecureElections::SecureElectionsQuestionType, { null: true }],
            "The questions of this election",
            null: false
      field :results_synced_at,
            Decidim::Core::DateTimeType,
            "When the tally was last read from the blockchain",
            null: true
      field :start_at, Decidim::Core::DateTimeType, "When this election starts accepting votes, if scheduled", null: true
      field :status, GraphQL::Types::String, "The lifecycle status of this election", null: false
      field :title, Decidim::Core::TranslatedFieldType, "The title of this election", null: false
      field :turnout,
            GraphQL::Types::Float,
            "Share of the census that has voted, as a percentage, when the census size is known",
            null: true
      field :url, GraphQL::Types::String, "The URL of this election", null: false
      field :votes_count, GraphQL::Types::Int, "How many votes have been cast in this election", null: false

      def url
        Decidim::ResourceLocatorPresenter.new(object).url
      end

      def turnout
        object.turnout&.round(2)
      end

      def self.authorized?(object, context)
        context[:election] = object

        super && allowed_to?(:read, :election, object, context)
      end
    end
  end
end
