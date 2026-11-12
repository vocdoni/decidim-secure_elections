/**
 * Per-question elections in Decidim's client-side booth. The booth page lists
 * only the questions the admin has open; each one is its own Vochain election,
 * published PAUSED and moved to READY when the admin opens it.
 *
 * - `waitUntilOpenOnChain` holds the ballot until the questions about to be
 *   voted are READY, so the CSP never signs a ballot the chain would reject.
 * - `watchForNextQuestion` polls upstream's `waiting.json` once the voter is
 *   done and reports a question the voter has yet to see open.
 * - `openInPlace` adds that question to the running booth and runs `prepare`
 *   again. The page is not reloaded, so the CSP session in memory survives and
 *   a 2FA census asks for one code per voter, not one per question.
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
 * Polls `waitingUrl` and calls `onOpen(boothUrl)` once when a question opens
 * that is not in `renderedIds`. Stops once no question is left to open.
 *
 * @param {Object} options - what to watch.
 * @param {string} options.waitingUrl - upstream's `waiting.json`.
 * @param {string[]} options.renderedIds - Decidim ids the booth has handled.
 * @param {Function} options.onWaiting - shows (string) or clears ("") the notice.
 * @param {string} options.message - the waiting notice.
 * @param {Function} options.onOpen - takes the booth URL.
 * @param {Object} [options.timings] - poll interval.
 * @returns {Function} stops the watcher.
 */
export const watchForNextQuestion = ({ waitingUrl, renderedIds, onWaiting, message, onOpen, timings = {} }) => {
  const { waitingPollMs } = { ...DEFAULTS, ...timings };
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
        onOpen(data.url);
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
  // `awaitingChain` keeps the question in the next-question watcher's sights.
  config.questions.forEach((question) => {
    question.awaitingChain = closed.includes(question);
  });
  closed.forEach((question) => {
    question.canVote = false;
  });

  return closed.length > 0 && !config.questions.some(votable)
    ? texts(config).not_open
    : null;
};

/**
 * Folds a freshly rendered booth config into the running one. Questions it
 * no longer lists have their results out: they stay for their receipts but are
 * marked `closed`. New ones are appended.
 *
 * @param {Object} config - the running booth config (mutated).
 * @param {Object} fresh - the config of the booth page just fetched.
 * @returns {void}
 */
export const mergeQuestions = (config, fresh) => {
  const open = (fresh && fresh.questions) || [];
  const openIds = new Set(open.map((question) => String(question.questionId)));
  const known = new Set(config.questions.map((question) => String(question.questionId)));

  config.questions.forEach((question) => {
    question.closed = !openIds.has(String(question.questionId));
  });
  config.questions.push(...open.filter((question) => !known.has(String(question.questionId))));
};

/**
 * Brings the questions open at `url` into the running booth and runs the
 * adapter's `prepare` again through `ctx.restart`. Loads `url` as a page when
 * the booth cannot do that (no `ctx.loadQuestions`, no booth at `url`, a
 * failed fetch).
 *
 * @param {Object} ctx - booth context.
 * @param {string} url - the booth URL from `waiting.json`.
 * @param {Function} [navigate] - defaults to `window.location.assign`.
 * @returns {Promise<void>} resolves once the booth has restarted.
 */
export const openInPlace = async (ctx, url, navigate = (target) => window.location.assign(target)) => {
  let loaded = null;
  try {
    loaded = ctx.loadQuestions && ctx.restart
      ? await ctx.loadQuestions(url)
      : null;
  } catch {
    loaded = null;
  }
  if (!loaded) {
    navigate(url);
    return;
  }

  mergeQuestions(ctx.config, loaded.config);
  await ctx.restart();
};

/**
 * One watcher per adapter: starting it again replaces the previous one. When
 * the booth can add questions in place, a question still waiting to open on
 * chain counts as not seen, so the booth tries it again while it stays open in
 * Decidim (a page load each time would ask for a new one-time code).
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
    const live = Boolean(ctx.loadQuestions && ctx.restart);
    stop();
    stop = watchForNextQuestion({
      waitingUrl: config.waitingUrl,
      renderedIds: config.questions.
        filter((question) => !(live && question.awaitingChain)).
        map((question) => question.questionId),
      onWaiting: ctx.progress,
      message: texts(config).waiting,
      onOpen: (url) => openInPlace(ctx, url)
    });
  };
};
