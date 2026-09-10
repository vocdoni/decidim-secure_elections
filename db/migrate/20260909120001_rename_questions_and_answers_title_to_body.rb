# frozen_string_literal: true

# Align the question/answer translatable text column with upstream
# `decidim-elections`, which names the field `body` on both
# `Decidim::Elections::Question` and `Decidim::Elections::ResponseOption`.
# Renaming closes a needless divergence: upstream's `LiveTextUpdateComponent`,
# which paints the collapsed question card's title as the admin types, is
# hard-coded to bind on `input[name$="[body_{locale}]"]`. As long as we
# named the column `title` the binding matched nothing and the header was
# stuck on the placeholder ("New question").
#
# Deployed data on decidim.vocdoni.io lives in a dev SaaS/vochain that we
# treat as ephemeral, so this can rename in place without a two-step
# migration.
class RenameQuestionsAndAnswersTitleToBody < ActiveRecord::Migration[8.0]
  def change
    rename_column :decidim_vocdoni_questions, :title, :body
    rename_column :decidim_vocdoni_answers, :title, :body
  end
end
