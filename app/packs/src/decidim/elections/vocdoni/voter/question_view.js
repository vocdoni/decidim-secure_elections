import { el, interpolate, textParagraphs } from "src/decidim/elections/vocdoni/voter/dom";

/**
 * One question of the ballot, as markup.
 *
 * This is the part of the voting page where moving from server-rendered HTML to
 * JavaScript could most easily have cost a voter their ballot, so it is kept in
 * its own module and reads as a template:
 *
 *   * a real `<fieldset>` with a real `<legend>`, so assistive technology
 *     announces the question when focus enters any of its choices;
 *   * the question's position in the ballot in the legend, visually hidden,
 *     because "Question 2 of 3" is in the counter but a screen reader reading
 *     the legend alone should still know where it is;
 *   * native `<input type="radio">` / `<input type="checkbox">`, one `name` per
 *     question, each with an `id` and a `<label for>` — which is what gives
 *     keyboard navigation, grouping and large click targets for free;
 *   * the description rendered as *text*: it comes from Decidim's rich-text
 *     editor by way of the Vocdoni API, and the voting page will not inject markup it
 *     did not build.
 */

/**
 * How many options this question wants, spelled out above the choices.
 *
 * @param {Object} question - the question.
 * @param {Object} i18n - the loaded translations.
 * @returns {string} the instruction.
 */
export const instructionFor = (question, i18n) => {
  const base = question.type === "multichoice"
    ? interpolate(i18n.ballot.pick_many, { min: question.minChoices, max: question.maxChoices })
    : i18n.ballot.pick_one;

  return question.secret
    ? `${base} ${i18n.ballot.secret}`
    : base;
};

/**
 * Builds one question's fieldset.
 *
 * @param {Object} question - the question, as normalized from the process.
 * @param {number} index - its index in `state.questions`.
 * @param {Object} i18n - the loaded translations.
 * @returns {Element} the fieldset, hidden until the ballot reaches it.
 */
export const buildQuestion = (question, index, i18n) => {
  const multiple = question.type === "multichoice";

  return el("fieldset", {
    class: "vocdoni-question",
    dataset: {
      questionIndex: index,
      questionId: question.vocdoniQuestionId,
      questionType: question.type
    },
    hidden: true
  }, [
    el("legend", { class: "vocdoni-question__title" }, [
      el("span", {
        class: "vocdoni-visually-hidden",
        text: `${interpolate(i18n.question_number, { number: index + 1 })} `
      }),
      el("span", { text: question.title })
    ]),
    textParagraphs(question.description).map((text) => el("p", { text })),
    el("p", { class: "vocdoni-hint", text: instructionFor(question, i18n) }),
    el("div", { class: "vocdoni-question__choices" }, question.choices.map((choice) => {
      const inputId = `vocdoni-answer-${index}-${choice.value}`;

      return el("label", { class: "vocdoni-choice", for: inputId }, [
        el("input", {
          type: multiple
            ? "checkbox"
            : "radio",
          id: inputId,
          name: `vocdoni_question_${index}`,
          value: String(choice.value),
          dataset: { answerValue: choice.value, answerLabel: choice.title }
        }),
        el("span", { text: choice.title })
      ]);
    })),
    el("p", { class: "vocdoni-error", "data-question-error": true, role: "alert", hidden: true })
  ]);
};

export default buildQuestion;
