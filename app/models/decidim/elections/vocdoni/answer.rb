# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    # A choice of a Vocdoni question. `value` is the 0-based integer actually
    # encoded in the ballot, so it must stay stable once the election is on
    # chain.
    class Answer < Vocdoni::ApplicationRecord
      include Decidim::Traceable
      include Decidim::Loggable
      include Decidim::TranslatableResource
      include Decidim::TranslatableAttributes

      belongs_to :question,
                 foreign_key: "decidim_vocdoni_question_id",
                 class_name: "Decidim::Elections::Vocdoni::Question",
                 inverse_of: :answers,
                 counter_cache: true

      has_one :election, through: :question

      translatable_fields :body

      validates :body, presence: true
      validates :value, presence: true,
                        numericality: { only_integer: true, greater_than_or_equal_to: 0 },
                        uniqueness: { scope: :decidim_vocdoni_question_id }

      default_scope { order(:position, :value, :id) }

      delegate :editable?, :on_chain?, to: :question
      delegate :component, :participatory_space, :organization, to: :question, allow_nil: true

      def presenter
        Decidim::Elections::Vocdoni::AnswerPresenter.new(self)
      end

      def self.log_presenter_class_for(_log)
        Decidim::Elections::Vocdoni::AdminLog::AnswerPresenter
      end

      # Share of the votes cast for the parent question. Reads the cached tally
      # only — never the API.
      def votes_percent
        total = question.votes_count
        return 0.0 unless total.positive?

        (votes_count.to_f / total) * 100
      end
    end
  end
end
end
