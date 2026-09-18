# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    class AnswerPresenter < Decidim::ResourcePresenter
      def answer
        __getobj__
      end

      def title(html_escape: false, all_locales: false)
        return unless answer

        super(answer.body, html_escape, all_locales)
      end
    end
  end
end
end
