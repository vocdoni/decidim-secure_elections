import { el, interpolate } from "src/decidim/elections/vocdoni/voter/dom";

/**
 * One line of the review screen, as markup.
 *
 * Kept beside `question_view.js` and for the same reason: the review is the
 * last thing a voter reads before anything leaves the browser, so what it says
 * about their ballot is worth being able to read on its own.
 *
 * The visible "Change" label is short because every row would otherwise carry
 * the same sentence; the accessible name names the question, and still starts
 * with the visible word so speech control keeps working.
 */

/**
 * The label a voter picked, by its on-chain value.
 *
 * Falls back to the value itself: a choice the process no longer lists is a
 * broken election rather than a broken screen, and showing the number is more
 * honest than showing nothing.
 *
 * @param {Object} question - the question, as normalized from the process.
 * @param {number} value - the choice value.
 * @returns {string} the label.
 */
export const answerLabel = (question, value) => {
  const choice = question.choices.find((candidate) => candidate.value === value);

  return choice
    ? choice.title
    : String(value);
};

/**
 * Builds one review row.
 *
 * @param {Object} options - the row's inputs.
 * @param {Object} options.question - the question being summarized.
 * @param {Object} options.i18n - the loaded translations.
 * @param {Function} options.onEdit - what to run when the voter changes it.
 * @returns {Element} the list item.
 */
export const buildReviewItem = ({ question, i18n, onEdit }) => {
  const labels = question.selected.map((value) => answerLabel(question, value));
  const edit = el("button", {
    type: "button",
    class: "vocdoni-button vocdoni-button--quiet vocdoni-button--small",
    "data-review-edit": true,
    "aria-label": interpolate(i18n.review.edit_label, { question: question.title }),
    text: i18n.review.edit
  });

  edit.addEventListener("click", onEdit);

  return el("li", { class: "vocdoni-review__item" }, [
    el("p", { class: "vocdoni-review__question", "data-review-question": true, text: question.title }),
    el("p", {
      "data-review-answers": true,
      text: labels.length > 0
        ? labels.join(", ")
        : i18n.review.not_answered
    }),
    edit
  ]);
};

export default buildReviewItem;
