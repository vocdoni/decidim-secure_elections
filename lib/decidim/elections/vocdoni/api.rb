# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    # GraphQL types for the Vocdoni component.
    #
    # They are autoloaded rather than required so that the schema classes are
    # only built when the API is actually used, and so that `component.rb` can
    # name `Decidim::Elections::Vocdoni::VocdoniElectionsType` at registration time.
    #
    # Names are prefixed because GraphQL type names are global to the schema:
    # `Decidim::Forms::QuestionType` already claims `Question`.
    autoload :VocdoniElectionsType, "decidim/api/vocdoni_elections_type"
    autoload :VocdoniElectionType, "decidim/api/vocdoni_election_type"
    autoload :VocdoniQuestionType, "decidim/api/vocdoni_question_type"
    autoload :VocdoniAnswerType, "decidim/api/vocdoni_answer_type"
  end
end
end
