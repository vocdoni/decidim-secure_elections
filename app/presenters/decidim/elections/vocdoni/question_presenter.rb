# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    class QuestionPresenter < Decidim::ResourcePresenter
      def question
        __getobj__
      end

      def title(html_escape: false, all_locales: false)
        return unless question

        super(question.body, html_escape, all_locales)
      end

      def description(all_locales: false)
        return unless question

        editor_locales(question.description, all_locales)
      end

      def type_name
        I18n.t(question.question_type, scope: "decidim.elections.vocdoni.question_types")
      end
    end
  end
end
end
