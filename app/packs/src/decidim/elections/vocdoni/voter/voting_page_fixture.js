/* global jest, __dirname */

import fs from "node:fs";
import path from "node:path";
import { createAuthStep } from "src/decidim/elections/vocdoni/voter/auth_step";
import { createBallotStep } from "src/decidim/elections/vocdoni/voter/ballot_step";
import { createReceiptStep } from "src/decidim/elections/vocdoni/voter/receipt_step";
import { createUi } from "src/decidim/elections/vocdoni/voter/ui";
import { QUESTION_STATE } from "src/decidim/elections/vocdoni/voter/submit_step";
import strings from "../../../../../../public/vocdoni/locales/en.json";

/**
 * Test-only fixture for the voting page's steps. Not imported by any entrypoint, so it
 * never reaches a bundle.
 *
 * It builds the **real** shell and the **real** steps: since the voting page became a
 * static page there is no ERB left to keep a hand-written copy of the markup in
 * step with, and a fixture that reproduced the markup would only be able to
 * prove itself right. What is stubbed is everything that would leave the page —
 * the Vocdoni flow — and the few UI methods a test needs to observe.
 *
 * The shell and the strings are the ones the gem actually ships
 * (`public/vocdoni/vote.html` and `public/vocdoni/locales`), so an id renamed
 * in the shell or a translation key removed from `en.vote.yml` without
 * rebuilding the voting page fails here rather than in front of a voter.
 */

export const i18n = strings;

const SHELL = path.join(__dirname, "../../../../../../public/vocdoni/vote.html");

/**
 * Paints the shipped shell into the test document.
 *
 * @returns {void} nothing.
 */
const renderShell = () => {
  // eslint-disable-next-line no-sync -- a test fixture, reading one small file.
  const parsed = new DOMParser().parseFromString(fs.readFileSync(SHELL, "utf8"), "text/html");

  document.body.innerHTML = parsed.body.innerHTML;
};

/**
 * An element by id.
 *
 * @param {string} id - the element id.
 * @returns {Element} the element, or null.
 */
export const byId = (id) => document.getElementById(id);

/**
 * Whether an element is on screen, i.e. present and not `hidden`.
 *
 * @param {Element} node - the element.
 * @returns {boolean} true when visible.
 */
export const visible = (node) => Boolean(node) && !node.hasAttribute("hidden");

/**
 * Types a value into a control.
 *
 * @param {string} selector - a CSS selector for the control.
 * @param {string} value - the value to type.
 * @returns {void} nothing.
 */
export const fill = (selector, value) => {
  document.querySelector(selector).value = value;
};

/**
 * Submits a form and lets the (async) handler settle.
 *
 * @param {string} id - the form's id.
 * @returns {Promise<void>} nothing.
 */
export const submit = async (id) => {
  byId(id).dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
};

/**
 * Clicks a button and lets the (async) handler settle.
 *
 * @param {string} id - the button's id.
 * @returns {Promise<void>} nothing.
 */
export const click = async (id) => {
  byId(id).click();
  await Promise.resolve();
  await Promise.resolve();
};

/**
 * A question as `process.js` normalizes it, ready to be dropped into the state.
 *
 * @param {Object} [overrides] - anything to change.
 * @returns {Object} the question.
 */
export const question = (overrides = {}) => ({
  index: 0,
  vocdoniQuestionId: "q1",
  processUpstreamId: "up1",
  title: "Who should chair the board?",
  description: "",
  type: "singlechoice",
  minChoices: 1,
  maxChoices: 1,
  secret: false,
  status: "ONGOING",
  choices: [
    { value: 0, title: "Alice" },
    { value: 1, title: "Bob" }
  ],
  upstreamId: null,
  canVote: true,
  hasVoted: false,
  selected: [],
  castState: QUESTION_STATE.PENDING,
  nullifier: null,
  ...overrides
});

/**
 * Builds the voting page shell and a context around stubbed collaborators.
 *
 * @param {Object} [options] - fixture options.
 * @param {Object[]} [options.questions] - the ballot's questions.
 * @param {string[]} [options.twoFaFields] - the census `twoFaFields`.
 * @returns {Object} the voting page context.
 */
export const context = ({ questions = [], twoFaFields = [] } = {}) => {
  renderShell();

  const flow = {
    twoFaFields: () => twoFaFields,
    authenticate: jest.fn().mockResolvedValue({
      needsOtp: twoFaFields.length > 0,
      channel: twoFaFields[0] || null
    }),
    confirmOtp: jest.fn().mockResolvedValue(),
    resendOtp: jest.fn().mockResolvedValue({ channel: twoFaFields[0] || null }),
    check: jest.fn().mockResolvedValue({ belongsToProcess: true, questions: [] }),
    castQuestion: jest.fn().mockResolvedValue({ nullifier: "0xdead" }),
    receipts: jest.fn().mockResolvedValue([]),
    reset: jest.fn()
  };

  const real = createUi({
    root: byId("js-vocdoni-vote"),
    i18n,
    exitUrl: "/processes/demo/f/1/elections/1",
    statusNode: byId("js-vocdoni-vote-status")
  });

  real.mount();

  // The shell is real; only what a test needs to observe is a spy.
  const ui = {
    stepNodes: real.stepNodes,
    exitLink: real.exitLink,
    heading: real.heading,
    // Both write to the real live region as well as recording the call: what a
    // step *stops* saying matters as much as what it says, and that is only
    // observable on the region itself.
    announce: jest.fn(real.announce),
    clearStatus: jest.fn(real.clearStatus),
    messageForError: jest.fn((error) => `message:${error.code}`),
    showInlineError: jest.fn(real.showInlineError),
    showStep: jest.fn(real.showStep),
    showError: jest.fn(),
    showBlocked: jest.fn()
  };

  return {
    flow,
    ui,
    i18n,
    params: { apiUrl: "https://api.example.org", processId: "6885f0c2c1a4e2f0b1d33a01" },
    state: {
      intent: "vote",
      title: "Board election 2026",
      questions,
      ballot: [],
      cursor: 0,
      submitting: false
    },
    ballot: { start: jest.fn() },
    receipt: { load: jest.fn().mockResolvedValue() }
  };
};

/**
 * Renders the identification and one-time-code steps, wired and bound.
 *
 * @param {Object} [options] - fixture options.
 * @param {string[]} [options.twoFaFields] - the census `twoFaFields`.
 * @param {string[]} [options.authFields] - the census `authFields`.
 * @returns {Object} the voting page context, plus the step under test.
 */
export const build = ({ twoFaFields = [], authFields = ["memberNumber"] } = {}) => {
  const ctx = context({ twoFaFields });
  const step = createAuthStep(ctx);

  step.bind();
  step.applyCensusFields(authFields, twoFaFields);

  return { ...ctx, step };
};

/**
 * Renders the ballot and review steps around a set of questions.
 *
 * @param {Object[]} questions - the questions, as `question()` builds them.
 * @returns {Object} the voting page context, plus the step under test.
 */
export const buildBallot = (questions) => {
  const ctx = context({ questions });
  const step = createBallotStep(ctx);

  step.bind();
  step.applyQuestions();

  return { ...ctx, step };
};

/**
 * Renders the receipt step around a set of questions.
 *
 * @param {Object} [options] - fixture options.
 * @param {Object[]} [options.questions] - the questions of the election.
 * @param {Object[]} [options.consumed] - what `signInfo` reports back.
 * @returns {Object} the voting page context, plus the step under test.
 */
export const buildReceipt = ({ questions = [], consumed = [] } = {}) => {
  const ctx = context({ questions });

  ctx.flow.receipts.mockResolvedValue(consumed);

  return { ...ctx, step: createReceiptStep(ctx) };
};

/**
 * Identifies as a two-factor voter and lands on the one-time-code screen.
 *
 * @param {Object} [options] - fixture options.
 * @param {string[]} [options.twoFaFields] - the census `twoFaFields`.
 * @param {boolean} [options.fakeTimers] - freeze time, for the cooldown tests.
 * @returns {Promise<Object>} the voting page context.
 */
export const openOtp = async ({ twoFaFields = ["email"], fakeTimers = false } = {}) => {
  if (fakeTimers) {
    jest.useFakeTimers();
    jest.setSystemTime(new Date("2026-07-27T12:00:00Z"));
  }

  const ctx = build({ twoFaFields });

  fill("[data-auth-field='memberNumber']", "2001");
  fill(`[data-twofa-field='${twoFaFields[0]}']`, "carol@example.org");
  await submit("js-vocdoni-auth-form");

  return ctx;
};
