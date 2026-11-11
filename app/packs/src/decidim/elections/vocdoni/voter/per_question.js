/**
 * Per-question elections in Decidim's client-side booth. The booth page lists
 * only the questions the admin has open; each one is its own Vochain election,
 * published PAUSED and moved to READY when the admin opens it. Two helpers:
 *
 * - `waitUntilOpenOnChain` holds the ballot until the questions about to be
 *   voted are READY, so the CSP never signs a ballot the chain would reject.
 * - `watchForNextQuestion` polls upstream's `waiting.json` once the voter is
 *   done and reloads the booth when the admin opens another question.
 */

// Chain statuses that accept ballots.
const OPEN_STATUSES = ["READY", "ONGOING"];

const DEFAULTS = {
  openPollMs: 3000,
  openTimeoutMs: 120000,
  waitingPollMs: 5000
};

const sleep = (ms) => new Promise((resolve) => {
  setTimeout(resolve, ms);
});

const stillClosed = (questions, remote) => {
  const statuses = new Map(((remote && remote.questions) || []).map((question) => [
    String(question.id || question.questionId),
    String(question.status || "").toUpperCase()
  ]));

  return questions.filter((question) => !OPEN_STATUSES.includes(statuses.get(question.vocdoniQuestionId)));
};

/**
 * Resolves once every question in `pending` is open on chain, re-reading the
 * process while any is not. Returns the questions still closed at timeout.
 *
 * @param {Object} options - what to wait for.
 * @param {Object} options.flow - the voter flow (`loadProcess`).
 * @param {Array} options.pending - booth questions the voter has yet to cast.
 * @param {Object} options.loaded - the process read the flow already made.
 * @param {Function} options.onWait - called once if the wait is needed.
 * @param {Object} [options.timings] - poll interval and timeout.
 * @returns {Promise<Array>} pending questions that are still not open.
 */
export const waitUntilOpenOnChain = async ({ flow, pending, loaded, onWait, timings = {} }) => {
  const { openPollMs, openTimeoutMs } = { ...DEFAULTS, ...timings };
  const deadline = Date.now() + openTimeoutMs;
  let closed = stillClosed(pending, loaded);

  if (closed.length > 0) {
    onWait();
  }
  while (closed.length > 0 && Date.now() < deadline) {
    await sleep(openPollMs);
    closed = stillClosed(closed, await flow.loadProcess());
  }

  return closed;
};

/**
 * Polls `waitingUrl` and navigates to the booth when a question opens that
 * this page did not render. Stops once no question is left to open.
 *
 * @param {Object} options - what to watch.
 * @param {string} options.waitingUrl - upstream's `waiting.json`.
 * @param {string[]} options.renderedIds - Decidim ids of the booth's questions.
 * @param {Function} options.onWaiting - shows (string) or clears ("") the notice.
 * @param {string} options.message - the waiting notice.
 * @param {Function} [options.navigate] - defaults to `window.location.assign`.
 * @param {Object} [options.timings] - poll interval.
 * @returns {Function} stops the watcher.
 */
export const watchForNextQuestion = ({ waitingUrl, renderedIds, onWaiting, message, navigate, timings = {} }) => {
  const { waitingPollMs } = { ...DEFAULTS, ...timings };
  const go = navigate || ((url) => window.location.assign(url));
  const rendered = new Set(renderedIds.map(String));
  let timer = null;
  let stopped = false;

  const stop = () => {
    stopped = true;
    clearTimeout(timer);
  };

  const tick = async () => {
    if (stopped) {
      return;
    }
    try {
      const response = await fetch(waitingUrl, { credentials: "same-origin", headers: { Accept: "application/json" } });
      const data = await response.json();
      const openIds = (data.open_question_ids || []).map(String);

      if (data.url && openIds.some((id) => !rendered.has(id))) {
        stop();
        go(data.url);
        return;
      }
      if (data.url && openIds.length === 0) {
        // Every question has its results published: nothing left to vote.
        stop();
        onWaiting("");
        return;
      }
      onWaiting(message);
    } catch {
      // A failed poll is retried on the next tick.
    }
    timer = setTimeout(tick, waitingPollMs);
  };

  // Deferred so the notice lands after the booth has drawn its receipt step.
  timer = setTimeout(tick, 0);

  return stop;
};

const texts = (config) => config.perQuestionI18n || {};

/**
 * Prepare-time gate for a per-question booth: waits for the questions the
 * voter has yet to cast to open on chain and marks any still closed as not
 * votable. A no-op for other elections.
 *
 * @param {Object} ctx - booth context (config, progress).
 * @param {Object} flow - the voter flow.
 * @param {Object} loaded - the process read the flow already made.
 * @returns {Promise<string|null>} a message when nothing is left to vote.
 */
export const holdUntilOpen = async (ctx, flow, loaded) => {
  const { config } = ctx;
  if (!config.perQuestion) {
    return null;
  }

  const votable = (question) => question.canVote && !question.hasVoted;
  const closed = await waitUntilOpenOnChain({
    flow,
    pending: config.questions.filter(votable),
    loaded,
    onWait: () => ctx.progress(texts(config).opening)
  });
  closed.forEach((question) => {
    question.canVote = false;
  });

  return closed.length > 0 && !config.questions.some(votable)
    ? texts(config).not_open
    : null;
};

/**
 * One watcher per adapter: starting it again replaces the previous one.
 *
 * @returns {Function} `(ctx) => void`, a no-op for other elections.
 */
export const createNextQuestionWatcher = () => {
  let stop = () => {};

  return (ctx) => {
    const { config } = ctx;
    if (!config.perQuestion || !config.waitingUrl) {
      return;
    }
    stop();
    stop = watchForNextQuestion({
      waitingUrl: config.waitingUrl,
      renderedIds: config.questions.map((question) => question.questionId),
      onWaiting: ctx.progress,
      message: texts(config).waiting
    });
  };
};
