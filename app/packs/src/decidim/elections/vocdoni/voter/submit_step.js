import { append, clear, el, focusElement, interpolate, qs, setDisabled, setText, toggle } from "src/decidim/elections/vocdoni/voter/dom";
import { ErrorCode, toVoteError } from "src/decidim/elections/vocdoni/voter/errors";

/**
 * Casting the ballot.
 *
 * Each question is its own transaction on the Vochain (ARCHITECTURE §1), so
 * progress is reported per question instead of behind one opaque spinner, and a
 * partial failure is reported as exactly that.
 *
 * The honesty rule: a relay we lost track of is `unconfirmed`, never `failed`.
 * The vote may well be on chain, and telling the voter it failed would push them
 * into casting a second ballot that the chain would reject.
 */

export const QUESTION_STATE = {
  PENDING: "pending",
  IN_PROGRESS: "in_progress",
  DONE: "done",
  UNCONFIRMED: "unconfirmed",
  FAILED: "failed"
};

/**
 * Wires the cast/submit step.
 *
 * @param {Object} ctx - the voting page context (flow, state, i18n and ui).
 * @returns {Object} `{ bind, applyQuestions }`.
 */
export const createSubmitStep = (ctx) => {
  const { flow, state, i18n, ui } = ctx;

  const list = el("ol", { id: "js-vocdoni-submit-list", class: "vocdoni-submit__list" });
  const message = el("p", {
    id: "js-vocdoni-submit-message",
    class: "vocdoni-submit__message",
    role: "status",
    "aria-live": "polite",
    "aria-atomic": "true"
  });

  const recheckButton = el("button", {
    type: "button",
    id: "js-vocdoni-submit-recheck",
    class: "vocdoni-button vocdoni-button--primary",
    text: i18n.submit.recheck,
    hidden: true
  });
  const retryButton = el("button", {
    type: "button",
    id: "js-vocdoni-submit-retry",
    class: "vocdoni-button vocdoni-button--primary",
    text: i18n.submit.retry,
    hidden: true
  });
  const castButton = ctx.ballot.castButton;

  /**
   * Writes the message under the cast list, and says which of its two jobs it
   * is doing. "Please keep this page open" is guidance and reads like the rest
   * of the page's quiet notes; "some of your votes could not be cast" is a
   * verdict and must not.
   *
   * @param {string} text - the message.
   * @param {string} tone - `working` or `verdict`.
   * @returns {void} nothing.
   */
  const say = (text, tone) => {
    setText(message, text);
    message.dataset.messageTone = tone;
  };

  append(ui.stepNodes.submit, [
    ui.heading(i18n.submit.title),
    list,
    message,
    el("div", { class: "vocdoni-nav" }, [recheckButton, retryButton])
  ]);

  const itemFor = (index) => qs(`[data-submit-question-index="${index}"]`, list);

  /**
   * Builds one progress row per question, once the election is known.
   *
   * @returns {void} nothing.
   */
  const applyQuestions = () => {
    clear(list);
    append(list, state.questions.map((question, index) => el("li", {
      class: "vocdoni-submit__item",
      dataset: { submitQuestionIndex: index, submitState: QUESTION_STATE.PENDING },
      hidden: true
    }, [
      el("span", { class: "vocdoni-submit__question", text: question.title }),
      el("span", { class: "vocdoni-submit__status" }, [
        el("span", { class: "vocdoni-submit__spinner", "data-submit-spinner": true, "aria-hidden": "true", hidden: true }),
        el("span", { "data-submit-state": true, text: i18n.submit.pending })
      ])
    ])));
  };

  const setQuestionState = (index, castState, detail = null) => {
    const item = itemFor(index);

    state.questions[index].castState = castState;

    if (!item) {
      return;
    }

    item.dataset.submitState = castState;
    setText(qs("[data-submit-state]", item), detail || i18n.submit[castState] || castState);
    toggle(qs("[data-submit-spinner]", item), castState === QUESTION_STATE.IN_PROGRESS);
  };

  // Leaving mid-relay can lose the receipt for a vote that is already in flight,
  // so we ask before the page goes away.
  const guardUnload = (event) => {
    event.preventDefault();
    event.returnValue = "";

    return "";
  };

  const finish = async () => {
    const states = state.ballot.map((index) => state.questions[index].castState);
    const unconfirmed = states.filter((value) => value === QUESTION_STATE.UNCONFIRMED).length;
    const failed = states.filter((value) => value === QUESTION_STATE.FAILED).length;

    if (unconfirmed === 0 && failed === 0) {
      ui.announce(i18n.status.done);
      await ctx.receipt.load();

      return;
    }

    const summary = unconfirmed > 0
      ? i18n.submit.summary_unconfirmed
      : i18n.submit.summary_failed;

    say(summary, "verdict");
    ui.announce(summary);
    toggle(recheckButton, unconfirmed > 0);
    toggle(retryButton, unconfirmed === 0);
    focusElement(unconfirmed > 0
      ? recheckButton
      : retryButton);
  };

  const castOne = async (index) => {
    const question = state.questions[index];

    setQuestionState(index, QUESTION_STATE.IN_PROGRESS, i18n.status.preparing);
    ui.announce(interpolate(i18n.status.casting, { question: question.title }));

    try {
      const { nullifier } = await flow.castQuestion({
        questionId: question.vocdoniQuestionId,
        upstreamId: question.upstreamId,
        selectedValues: question.selected,
        onProgress: (phase) => setQuestionState(index, QUESTION_STATE.IN_PROGRESS, i18n.status[phase])
      });

      question.nullifier = nullifier;
      question.hasVoted = true;
      setQuestionState(index, QUESTION_STATE.DONE);
    } catch (error) {
      const voteError = toVoteError(error);
      const unconfirmed = voteError.code === ErrorCode.RELAY_UNCONFIRMED || voteError.code === ErrorCode.NETWORK;

      setQuestionState(
        index,
        unconfirmed
          ? QUESTION_STATE.UNCONFIRMED
          : QUESTION_STATE.FAILED,
        ui.messageForError(voteError)
      );
    }
  };

  const castAll = async () => {
    state.submitting = true;
    window.addEventListener("beforeunload", guardUnload);
    toggle(retryButton, false);
    toggle(recheckButton, false);
    say(i18n.submit.in_flight, "working");

    const pending = state.ballot.filter((index) => state.questions[index].castState !== QUESTION_STATE.DONE);

    // Sequential on purpose: each question consumes its own CSP signing slot,
    // and a serial run keeps the per-question progress honest.
    for (const index of pending) {
      await castOne(index);
    }

    window.removeEventListener("beforeunload", guardUnload);
    state.submitting = false;

    await finish();
  };

  /**
   * "Did my vote land?" — re-asks the CSP instead of guessing. This is the only
   * honest answer available after a relay we lost track of.
   *
   * @returns {Promise<void>} nothing.
   */
  const handleRecheck = async () => {
    setDisabled(recheckButton, true);
    say(i18n.submit.rechecking, "working");

    try {
      const result = await flow.check();
      const byQuestionId = new Map(result.questions.map((item) => [item.questionId, item]));

      state.ballot.forEach((index) => {
        const question = state.questions[index];
        const remote = byQuestionId.get(question.vocdoniQuestionId);

        if (remote && remote.hasVoted) {
          question.hasVoted = true;
          setQuestionState(index, QUESTION_STATE.DONE);
        } else if (question.castState === QUESTION_STATE.UNCONFIRMED) {
          setQuestionState(index, QUESTION_STATE.FAILED, i18n.submit.confirmed_missing);
        }
      });

      toggle(recheckButton, false);
      await finish();
    } catch (error) {
      say(ui.messageForError(error), "verdict");
    } finally {
      setDisabled(recheckButton, false);
    }
  };

  const handleRetry = async () => {
    state.ballot.forEach((index) => {
      if (state.questions[index].castState === QUESTION_STATE.FAILED) {
        setQuestionState(index, QUESTION_STATE.PENDING);
      }
    });

    await castAll();
  };

  const handleCast = async () => {
    setDisabled(castButton, true);

    state.questions.forEach((question, index) => {
      const inBallot = state.ballot.includes(index);

      toggle(itemFor(index), inBallot);

      if (inBallot) {
        setQuestionState(index, question.castState);
      }
    });

    ui.showStep("submit");

    try {
      await castAll();
    } finally {
      setDisabled(castButton, false);
    }
  };

  /**
   * Attaches the cast, retry and re-check handlers.
   *
   * @returns {void} nothing.
   */
  const bind = () => {
    castButton.addEventListener("click", handleCast);
    recheckButton.addEventListener("click", handleRecheck);
    retryButton.addEventListener("click", handleRetry);
  };

  return { bind, applyQuestions };
};

export default createSubmitStep;
