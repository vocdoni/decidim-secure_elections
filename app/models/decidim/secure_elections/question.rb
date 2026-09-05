# frozen_string_literal: true

module Decidim
  module SecureElections
    # A question of a Vocdoni election.
    #
    # Careful: a question is **not** just a field of the process. Each question
    # is its own Vochain election, identified by `vocdoni_upstream_id`. That id
    # — never the process id — is what the browser signs and votes against
    # (ARCHITECTURE §1).
    class Question < SecureElections::ApplicationRecord
      include Decidim::Traceable
      include Decidim::Loggable
      include Decidim::TranslatableResource
      include Decidim::TranslatableAttributes

      # Lowercase on purpose: camelCase is rejected upstream with code 40037.
      QUESTION_TYPES = %w(singlechoice multichoice).freeze

      # Per-question lifecycle, mirroring the API's QuestionStatus. Stored
      # lowercase, sent upcased. `ongoing` is reported by the API for a
      # question that is accepting votes; it is not something an admin sets.
      STATUSES = %w(ready ongoing paused ended results canceled).freeze

      belongs_to :election,
                 foreign_key: "decidim_vocdoni_election_id",
                 class_name: "Decidim::SecureElections::Election",
                 inverse_of: :questions

      has_many :answers,
               foreign_key: "decidim_vocdoni_question_id",
               class_name: "Decidim::SecureElections::Answer",
               inverse_of: :question,
               dependent: :destroy

      translatable_fields :title, :description

      validates :title, presence: true
      validates :question_type, inclusion: { in: QUESTION_TYPES }
      validates :max_choices, :min_choices,
                numericality: { only_integer: true, greater_than: 0 },
                allow_nil: true
      validate :choice_bounds_within_answers

      default_scope { order(:position, :id) }

      delegate :editable?, :on_chain?, to: :election
      # Not a `HasComponent` model, but the admin log reads these to attribute
      # an entry to the right space.
      delegate :component, :participatory_space, :organization, to: :election, allow_nil: true

      def presenter
        Decidim::SecureElections::QuestionPresenter.new(self)
      end

      def self.log_presenter_class_for(_log)
        Decidim::SecureElections::AdminLog::QuestionPresenter
      end

      # @param value [String, nil] the API's status, e.g. "READY" or "ONGOING"
      # @return [String, nil] a member of STATUSES, or nil when unrecognised
      def self.normalize_status(value)
        status = value.to_s.downcase.presence
        STATUSES.include?(status) ? status : nil
      end

      def singlechoice?
        question_type == "singlechoice"
      end

      def multichoice?
        question_type == "multichoice"
      end

      # A question needs at least two answers to be a meaningful ballot, and a
      # multichoice question needs coherent bounds.
      def complete?
        return false if answers.size < 2
        return true unless multichoice?

        effective_max_choices.between?(effective_min_choices, answers.size) && effective_min_choices.positive?
      end

      def effective_max_choices
        max_choices.presence || answers.size
      end

      def effective_min_choices
        min_choices.presence || 1
      end

      # The status as the API expects it.
      def upstream_status
        vocdoni_status.presence&.upcase
      end

      def votes_count
        results["votes_count"].to_i
      end

      # Local read of the election's cached tally for this question.
      def results
        cache = election.results_cache
        return {} unless cache.is_a?(Hash)

        cache.dig("questions", id.to_s) || {}
      end

      def next_position
        (answers.maximum(:position) || -1) + 1
      end

      # The next free 0-based on-chain choice value.
      def next_value
        (answers.maximum(:value) || -1) + 1
      end

      # Ballot encoding assumes choice values are contiguous and 0-based, so any
      # mutation of the answer set has to renumber the survivors. Uses
      # `update_columns` on purpose: this is bookkeeping, not an editorial
      # change, and it must not pollute the version history.
      def resequence_answers!
        answers.reload.each_with_index do |answer, index|
          next if answer.position == index && answer.value == index

          answer.update_columns(position: index, value: index) # rubocop:disable Rails/SkipsModelValidations
        end
      end

      private

      def choice_bounds_within_answers
        return unless multichoice?
        return if max_choices.blank? || min_choices.blank?
        return if max_choices >= min_choices

        errors.add(:max_choices, :invalid)
      end
    end
  end
end
