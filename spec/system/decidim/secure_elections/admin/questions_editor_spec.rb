# frozen_string_literal: true

require "spec_helper"

# The Questions tab: ballot editor powered by upstream decidim-forms'
# DynamicFieldsComponent (clone-from-template, soft-delete) and
# html5sortable (drag-reorder).
#
# DOM contract verified here:
#   .card.questionnaire-question — one per question, rendered server-side
#   select[name*='[question_type]'] — per-question select, inside each card
#   script#question-template — blueprint cloned by DynamicFieldsComponent
#   button.add-question — outside the form; DynamicFieldsComponent wires click
#   input[name*='[deleted]'] — soft-delete sentinel set by JS on Remove
#
# Server-side persistence (add / remove / position / multichoice) is covered
# by spec/commands/decidim/secure_elections/admin/update_election_questions_spec.rb.
describe "Admin Questions editor" do
  include_context "when managing a component as an admin"

  let(:manifest_name) { "vocdoni" }
  let(:election_path) { Decidim::EngineRouter.admin_proxy(component) }
  let!(:election) do
    create(:vocdoni_election, :with_questions, component:, questions_count: 2, answers_count: 2)
  end

  before do
    visit election_path.edit_election_questions_path(election)
  end

  it "renders one .card.questionnaire-question per existing question" do
    expect(page).to have_css(".card.questionnaire-question", count: 2)
  end

  it "gives each question card its own question_type select" do
    # Per-question type: every card has its own select so singlechoice and
    # multichoice questions can coexist on the same ballot. The card body
    # sits inside an a11y-accordion collapsible panel, so on initial load
    # the select is in the DOM but may be `visible: :hidden`.
    within ".questionnaire-questions-list" do
      selects = all("select[name*='[question_type]']", visible: :all)
      expect(selects.size).to eq(2)
    end
  end

  it "renders the #question-template blueprint for DynamicFieldsComponent" do
    # The <script type="text/template"> is inert until DynamicFieldsComponent
    # clones it when the admin clicks "Add question".
    expect(page.body).to include("question-template")
  end

  it "renders the .add-question button that DynamicFieldsComponent listens on" do
    expect(page).to have_button(I18n.t("decidim.secure_elections.admin.questions.form.add_question"))
  end

  it "includes a hidden deleted sentinel in each question card" do
    # DynamicFieldsComponent sets deleted=true on Remove; the server excludes
    # deleted questions from the saved set without losing the other fields.
    within all(".card.questionnaire-question").first do
      expect(page).to have_css("input[type='hidden'][name*='[deleted]']", visible: :hidden)
    end
  end

  it "includes a sortable list wrapper with the draggable data attributes" do
    # html5sortable reads data-draggable-table and data-draggable-handle.
    expect(page).to have_css(".questionnaire-questions-list[data-draggable-table]")
  end
end
