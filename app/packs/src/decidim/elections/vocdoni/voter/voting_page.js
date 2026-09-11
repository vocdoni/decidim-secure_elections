import { createVoterFlow } from "src/decidim/elections/vocdoni/voter/flow";
import { createUi } from "src/decidim/elections/vocdoni/voter/ui";
import { createAuthStep } from "src/decidim/elections/vocdoni/voter/auth_step";
import { createBallotStep } from "src/decidim/elections/vocdoni/voter/ballot_step";
import { createSubmitStep, QUESTION_STATE } from "src/decidim/elections/vocdoni/voter/submit_step";
import { createReceiptStep } from "src/decidim/elections/vocdoni/voter/receipt_step";
import { isVotingOpen, normalizeProcess } from "src/decidim/elections/vocdoni/voter/process";
import { clear, setText } from "src/decidim/elections/vocdoni/voter/dom";

/**
 * Assembles the voting page: one shared state object, one step machine and the
 * step modules, wired around a `createVoterFlow` instance.
 *
 * Everything the voting page shows comes from two places and two places only: the
 * query string it was opened with (`params.js`) and the *public* process read
 * (`process.js`). There is no server behind this page — no session, no
 * configuration island, no privileged endpoint — which is precisely why it can
 * be a file shipped inside the gem.
 *
 * The voting page holds the voter's selections in memory only. Nothing is written to a
 * URL, to storage or to a cookie, and nothing is logged — ARCHITECTURE §0.4,
 * enforced by the `no-console` and `no-restricted-globals` overrides in
 * `eslint.config.mjs`.
 */

/**
 * Builds a voting page.
 *
 * @param {Object} options - the voting page's inputs.
 * @param {Element} options.root - the container the shell is built into.
 * @param {Object} options.params - the parsed query string.
 * @param {Object} options.i18n - the loaded translations.
 * @param {string} options.locale - the locale in use, for the API's language
 *   maps.
 * @param {Element} [options.statusNode] - the shared `aria-live` region.
 * @param {Element} [options.titleNode] - the banner heading to fill in.
 * @param {Element} [options.exitNode] - where the banner's exit link goes.
 * @returns {Object} `{ start, state }`.
 */
export const createVotingPage = ({ root, params, i18n, locale, statusNode = null, titleNode = null, exitNode = null }) => {
  const ctx = {
    root,
    params,
    i18n,
    locale,
    flow: createVoterFlow({
      apiUrl: params.apiUrl,
      processId: params.processId
    }),
    state: {
      // The voting page is entered to vote. A voter who has nothing left to cast is
      // shown their receipts instead, which is decided after `check`, not here.
      intent: "vote",
      title: "",
      // One entry per question of the process, in ballot order.
      questions: [],
      // Indexes (into state.questions) the voter is actually being asked.
      ballot: [],
      cursor: 0,
      submitting: false
    }
  };

  ctx.ui = createUi({ root, i18n, exitUrl: params.exitUrl, statusNode });
  ctx.ui.mount();

  // Wired in dependency order: the receipt is self-contained, the submit step
  // borrows the review screen's "cast" button, and authentication ends in either
  // a ballot or a receipt.
  ctx.receipt = createReceiptStep(ctx);
  ctx.ballot = createBallotStep(ctx);
  ctx.submit = createSubmitStep(ctx);
  ctx.auth = createAuthStep(ctx);

  /**
   * Fills the voting page in from the process read.
   *
   * @param {Object} process - a normalized process.
   * @returns {void} nothing.
   */
  const applyProcess = (process) => {
    ctx.state.title = process.title;
    ctx.state.questions = process.questions.map((question) => ({
      ...question,
      // Learned per voter from `processes.check`; the process read's own value
      // is kept as a fallback (see `auth_step`).
      upstreamId: null,
      canVote: false,
      hasVoted: false,
      selected: [],
      castState: QUESTION_STATE.PENDING,
      nullifier: null
    }));

    setText(titleNode, process.title);

    if (exitNode) {
      clear(exitNode);
      const link = ctx.ui.exitLink(i18n.exit);

      if (link) {
        exitNode.appendChild(link);
      }
    }

    if (process.title) {
      document.title = `${process.title} — ${i18n.page_title}`;
    }

    // Both lists come from the live process read: a census edited after the
    // voting page link was handed out still produces the right form, and a census that
    // grew a 2FA requirement still enforces it.
    ctx.auth.applyCensusFields(process.authFields, process.twoFaFields);
    ctx.auth.showClosedNotice(!isVotingOpen(process));
    ctx.ballot.applyQuestions();
    ctx.submit.applyQuestions();
  };

  /**
   * Reads the process, then hands over to the census authentication step.
   *
   * @returns {Promise<void>} nothing.
   */
  const start = async () => {
    ctx.ui.showStep("loading");
    ctx.ui.announce(i18n.status.loading);
    // A retry after a mid-flow failure must not inherit a half-authenticated
    // token — in particular one that passed `authStep0` but never 2FA.
    ctx.flow.reset();

    try {
      applyProcess(normalizeProcess(await ctx.flow.loadProcess(), locale));
    } catch (error) {
      ctx.ui.showError(error);

      return;
    }

    // The election is loaded and the identification form is drawn, so the status
    // line has nothing left to report; the step heading takes over from here.
    ctx.ui.clearStatus();
    ctx.ui.showStep("auth");
  };

  ctx.auth.bind();
  ctx.ballot.bind();
  ctx.submit.bind();
  ctx.ui.onRetry(start);

  return { start, state: ctx.state };
};

export default createVotingPage;
