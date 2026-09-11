import { validateSelection } from "src/decidim/elections/vocdoni/voter/ballot";
import { append, clear, el, focusElement, interpolate, qs, qsa, setText, toggle } from "src/decidim/elections/vocdoni/voter/dom";
import { buildQuestion } from "src/decidim/elections/vocdoni/voter/question_view";
import { buildReviewItem } from "src/decidim/elections/vocdoni/voter/review_view";
import { createRecordedNotice } from "src/decidim/elections/vocdoni/voter/recorded_notice";

/**
 * The ballot and the review screen.
 *
 * One question per screen, each built by `question_view.js` as a real
 * `<fieldset>` with a `<legend>` and native radios or checkboxes — the same
 * markup the server used to render, built here instead because there is no
 * server any more.
 *
 * The fieldsets are built **once**, when the process is read, and then shown and
 * hidden. Rebuilding them on every navigation would throw away the voter's
 * selection, break the association between a label and its input for assistive
 * technology, and drop focus back to the top of the document on every "next".
 *
 * The ballot is not always the whole election: a voter interrupted mid-cast
 * comes back to one holding only the questions they have left. So the counter
 * numbers questions by their position in the *election* — which is how the
 * legend has always numbered them — and `recorded_notice.js` names the ones
 * already in, on this screen and on the review, whose reassurance is chosen to
 * match.
 */

/**
 * Wires the ballot and review steps.
 *
 * @param {Object} ctx - the voting page context (state, i18n and ui).
 * @returns {Object} `{ bind, applyQuestions, start, goTo, renderReview }`.
 */
export const createBallotStep = (ctx) => {
  const { state, i18n, ui } = ctx;

  const counter = el("p", { id: "js-vocdoni-ballot-counter", class: "vocdoni-hint", "aria-live": "polite", "aria-atomic": "true" });
  const questionList = el("div", { id: "js-vocdoni-ballot-form" });
  const backButton = el("button", {
    type: "button",
    id: "js-vocdoni-ballot-back",
    class: "vocdoni-button vocdoni-button--quiet",
    text: i18n.ballot.back,
    hidden: true
  });
  const nextButton = el("button", {
    type: "button",
    id: "js-vocdoni-ballot-next",
    class: "vocdoni-button vocdoni-button--primary",
    text: i18n.ballot.next
  });
  const ballotNotice = createRecordedNotice(i18n);
  const reviewNotice = createRecordedNotice(i18n);
  // `data-review-state` tells the two wordings apart on screen as well as in
  // the copy — see `renderReview`.
  const reviewBody = el("p", {
    id: "js-vocdoni-review-body",
    class: "vocdoni-review__lead",
    dataset: { reviewState: "fresh" },
    text: i18n.review.body
  });
  const reviewList = el("ul", { id: "js-vocdoni-review-list", class: "vocdoni-review" });
  const reviewBack = el("button", {
    type: "button",
    id: "js-vocdoni-review-back",
    class: "vocdoni-button vocdoni-button--quiet",
    text: i18n.review.back
  });
  const castButton = el("button", {
    type: "button",
    id: "js-vocdoni-cast",
    class: "vocdoni-button vocdoni-button--primary",
    text: i18n.review.cast
  });

  // The ballot's own heading is structural: the question's `<legend>` is what
  // the voter is actually being asked, so the step heading stays out of the way
  // visually while still giving the step a name in the document outline and a
  // focus target on entry. Its text needs the election title, which only
  // arrives with the process read, so it is filled in by `applyQuestions`.
  const ballotHeading = ui.heading("", { visuallyHidden: true });

  append(ui.stepNodes.ballot, [
    ballotHeading,
    ballotNotice.node,
    counter,
    questionList,
    el("div", { class: "vocdoni-nav" }, [backButton, nextButton])
  ]);

  append(ui.stepNodes.review, [
    ui.heading(i18n.review.title),
    reviewBody,
    reviewNotice.node,
    reviewList,
    el("div", { class: "vocdoni-nav" }, [reviewBack, castButton])
  ]);

  const questionNode = (index) => qs(`[data-question-index="${index}"]`, questionList);

  const readSelection = (index) => qsa(`[data-question-index="${index}"] [data-answer-value]:checked`, questionList).
    map((input) => Number(input.value));

  const currentIndex = () => state.ballot[state.cursor];

  /**
   * The questions this voter already has on the network, as `check` reported
   * them.
   *
   * @returns {Object[]} the recorded questions, in election order.
   */
  const recordedQuestions = () => state.questions.filter((question) => question.hasVoted);

  /**
   * Builds every question of the election, once.
   *
   * @returns {void} nothing.
   */
  const applyQuestions = () => {
    setText(ballotHeading, interpolate(i18n.ballot.title, { title: state.title }));
    clear(questionList);
    append(questionList, state.questions.map((question, index) => buildQuestion(question, index, i18n)));
  };

  /**
   * Shows the question at the current cursor and updates the navigation.
   *
   * @returns {void} nothing.
   */
  const render = () => {
    state.questions.forEach((_question, index) => {
      toggle(questionNode(index), state.ballot[state.cursor] === index);
    });

    // By position in the election, not in the ballot: the legend right
    // underneath says "Question 2", and a counter reading "Question 1 of 1"
    // over it is the voting page contradicting itself where a resuming voter is
    // looking hardest for reassurance.
    setText(counter, interpolate(i18n.ballot.counter, {
      current: currentIndex() + 1,
      total: state.questions.length
    }));

    toggle(backButton, state.cursor > 0);
    setText(nextButton, state.cursor === state.ballot.length - 1
      ? i18n.ballot.review
      : i18n.ballot.next);
  };

  /**
   * Moves to a position in the ballot and shows it.
   *
   * @param {number} position - index into `state.ballot`.
   * @returns {void} nothing.
   */
  const goTo = (position) => {
    state.cursor = position;
    render();
    // Whatever the status line last said is over — in particular a validation
    // message the voter has just acted on. Greeting somebody with the error
    // they have already fixed teaches them to ignore the one channel that later
    // has to carry a real failure.
    ui.clearStatus();
    ui.showStep("ballot");
    focusElement(qs("legend", questionNode(currentIndex())));
  };

  /**
   * Rebuilds the review list from the recorded selections.
   *
   * @returns {void} nothing.
   */
  const renderReview = () => {
    const recorded = recordedQuestions();

    // "Nothing has been sent yet" is true for a voter starting from scratch and
    // false for one resuming an interrupted cast — whose earlier vote is on the
    // network and whose receipt for it turns up two screens later. Saying it to
    // them anyway is the voting page telling a voter something it knows to be untrue.
    // The state goes on the element too, so the two facts do not merely read
    // differently but *look* different on the screen a resuming voter scans for
    // exactly this.
    const resuming = recorded.length > 0;

    setText(reviewBody, resuming
      ? i18n.review.body_partial
      : i18n.review.body);
    reviewBody.dataset.reviewState = resuming
      ? "partial"
      : "fresh";
    reviewNotice.update(recorded, state.questions);

    clear(reviewList);

    append(reviewList, state.ballot.map((questionIndex, position) => buildReviewItem({
      question: state.questions[questionIndex],
      i18n,
      onEdit: () => goTo(position)
    })));
  };

  /**
   * Enters the ballot with the questions this voter may answer.
   *
   * @param {number[]} indexes - indexes into `state.questions`.
   * @returns {void} nothing.
   */
  const start = (indexes) => {
    const recorded = recordedQuestions();

    state.ballot = indexes;
    ballotNotice.update(recorded, state.questions);
    goTo(0);

    // Focus lands on the legend, which comes *after* the notice, so reading
    // forward from there never reaches it. The live region is what makes sure
    // a resuming voter is told rather than left to find out.
    if (recorded.length > 0) {
      ui.announce(i18n.ballot.already_recorded.title);
    }
  };

  const handleNext = () => {
    const index = currentIndex();
    const question = state.questions[index];
    const selected = readSelection(index);
    const { valid, reason } = validateSelection(question, selected);
    const errorNode = qs("[data-question-error]", questionNode(index));

    if (!valid) {
      const message = interpolate(i18n.validation[reason], {
        min: question.minChoices,
        max: question.maxChoices
      });

      ui.showInlineError(errorNode, message);
      ui.announce(message);
      focusElement(errorNode);

      return;
    }

    ui.showInlineError(errorNode, null);
    question.selected = selected;

    if (state.cursor < state.ballot.length - 1) {
      goTo(state.cursor + 1);

      return;
    }

    renderReview();
    // Same as `goTo`: the ballot is behind the voter, and so is anything the
    // status line was still saying about it.
    ui.clearStatus();
    ui.showStep("review");
  };

  const handleBack = () => {
    if (state.cursor > 0) {
      goTo(state.cursor - 1);
    }
  };

  /**
   * Attaches the navigation handlers.
   *
   * @returns {void} nothing.
   */
  const bind = () => {
    nextButton.addEventListener("click", handleNext);
    backButton.addEventListener("click", handleBack);
    reviewBack.addEventListener("click", () => goTo(0));

    // Clear a validation message as soon as the voter acts on it. Delegated
    // from the list, because the fieldsets are built after this runs.
    questionList.addEventListener("change", (event) => {
      const fieldset = event.target && event.target.closest("[data-question-index]");

      if (fieldset) {
        ui.showInlineError(qs("[data-question-error]", fieldset), null);
      }
    });
  };

  return { bind, applyQuestions, start, goTo, renderReview, castButton };
};

export default createBallotStep;
