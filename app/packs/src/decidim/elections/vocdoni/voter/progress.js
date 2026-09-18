import { append, el, qsa, toggle } from "src/decidim/elections/vocdoni/voter/dom";

/**
 * The progress trail: "1 Identify — 2 Choose — 3 Review — 4 Receipt".
 *
 * It is the only thing on screen that claims to describe the *whole* flow, so
 * it is the one thing that must never describe a screen the voter has left.
 * That is why the step-to-stage table, the "where are we" arithmetic and the
 * markup live together in one file: they used to be three thirds of an answer
 * scattered through the shell, and the stage the trail highlighted drifted away
 * from the heading underneath it.
 */

/**
 * Which progress stage each step belongs to.
 *
 * `otp` folds into `auth`: confirming a code is still identifying yourself.
 *
 * `submit` folds into `receipt`, not into `review`. Review is over the instant
 * the voter presses "cast my vote" — from there on the voting page is producing the
 * receipt, and a trail still pointing at "Review" underneath a heading that
 * reads "Casting your vote" is describing a screen that is no longer there.
 */
const STAGE_FOR_STEP = {
  auth: "auth",
  otp: "auth",
  ballot: "ballot",
  review: "review",
  submit: "receipt",
  receipt: "receipt"
};

/** The stages, in the order the voter meets them. */
const STAGES = ["auth", "ballot", "review", "receipt"];

/** Indexed by `Math.sign(stageIndex - currentIndex) + 1`. */
const STATES = ["done", "current", "upcoming"];

/**
 * Builds the trail and the means to move it along.
 *
 * @param {Object} options - configuration.
 * @param {Object} options.i18n - the loaded translations.
 * @returns {Object} `{ nav, build, update }`.
 */
export const createProgress = ({ i18n }) => {
  const list = el("ol", { id: "js-vocdoni-vote-progress", class: "vocdoni-progress" });
  const nav = el("nav", {
    class: "vocdoni-progress__nav",
    "aria-label": i18n.progress.label,
    hidden: true
  }, list);

  /**
   * Paints one item per stage. Called once, from the shell's `mount`.
   *
   * @returns {void} nothing.
   */
  const build = () => append(list, STAGES.map((stage, index) => el("li", {
    class: "vocdoni-progress__item",
    dataset: { progressStep: stage }
  }, [
    el("span", { class: "vocdoni-progress__marker", "aria-hidden": "true", text: String(index + 1) }),
    el("span", { class: "vocdoni-progress__label", text: i18n.progress[stage] })
  ])));

  /**
   * Marks what is behind the voter, where they are and what is left, and hides
   * the trail on the steps it does not describe.
   *
   * `aria-current` and `data-progress-state` come off the same index, so what is
   * read out and what is coloured in cannot disagree.
   *
   * @param {string} step - the step being shown.
   * @returns {void} nothing.
   */
  const update = (step) => {
    const stage = STAGE_FOR_STEP[step];
    const currentIndex = STAGES.indexOf(stage);

    qsa("[data-progress-step]", list).forEach((item) => {
      const index = STAGES.indexOf(item.dataset.progressStep);

      if (index === currentIndex) {
        item.setAttribute("aria-current", "step");
      } else {
        item.removeAttribute("aria-current");
      }

      item.dataset.progressState = STATES[Math.sign(index - currentIndex) + 1];
    });

    toggle(nav, Boolean(stage));
  };

  return { nav, build, update };
};

export default createProgress;
