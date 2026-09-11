import { append, clear, el, interpolate, toggle } from "src/decidim/elections/vocdoni/voter/dom";

/**
 * "Part of your ballot is already recorded."
 *
 * A voter who closed the tab midway through casting comes back, identifies
 * again, and is offered only the questions they have left — that resume
 * behaviour is right, and it is not what this module changes. What it changes is
 * that the voting page used to do it *silently*: the ballot simply had fewer questions
 * in it than the election did, and nothing on screen said why.
 *
 * That silence lands on precisely the person least able to absorb it. Somebody
 * interrupted mid-cast is already wondering whether their vote counted; showing
 * them a shorter ballot with no explanation invites the reading that the earlier
 * answers were lost. The voting page knows the truth — `processes.check` told it which
 * questions are recorded — so it says it, and names them.
 *
 * The same notice is shown on the ballot and on the review screen, which is why
 * it is a factory rather than a node: two screens, two instances, one wording.
 */

/**
 * Builds a notice naming the questions already recorded for this voter.
 *
 * @param {Object} i18n - the loaded translations.
 * @returns {Object} `{ node, update }` — the element, and the way to fill it in.
 */
export const createRecordedNotice = (i18n) => {
  const list = el("ul", { class: "vocdoni-recorded__list", "data-recorded-list": true });
  const node = el("div", {
    class: "vocdoni-notice vocdoni-recorded",
    "data-recorded-notice": true,
    hidden: true
  }, [
    el("p", { class: "vocdoni-recorded__title", "data-recorded-title": true, text: i18n.ballot.already_recorded.title }),
    el("p", { text: i18n.ballot.already_recorded.body }),
    el("p", { class: "vocdoni-hint", text: i18n.ballot.already_recorded.list_label }),
    list
  ]);

  /**
   * Names the recorded questions, or hides the notice when there are none.
   *
   * The questions are numbered exactly as the ballot's own legends and counter
   * number them — their position in the election — so a voter can line
   * "Question 1" in this list up against "Question 2 of 2" above the fieldset
   * without having to work out which numbering scheme either of them is using.
   *
   * @param {Object[]} questions - the recorded questions, in election order.
   * @param {Object[]} allQuestions - every question of the election, for numbering.
   * @returns {void} nothing.
   */
  const update = (questions, allQuestions) => {
    clear(list);
    append(list, questions.map((question) => el("li", {
      "data-recorded-question": true,
      text: `${interpolate(i18n.question_number, { number: allQuestions.indexOf(question) + 1 })} ${question.title}`
    })));
    toggle(node, questions.length > 0);
  };

  return { node, update };
};

export default createRecordedNotice;
