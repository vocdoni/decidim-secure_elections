/* global jest */
/* eslint-disable camelcase -- open_question_ids is the server's JSON key */

import { createNextQuestionWatcher, mergeQuestions, openInPlace, waitUntilOpenOnChain, watchForNextQuestion } from "src/decidim/elections/vocdoni/voter/per_question";

const remote = (statuses) => ({
  questions: Object.entries(statuses).map(([id, status]) => ({ id, status }))
});

const fast = { openPollMs: 1, openTimeoutMs: 50, waitingPollMs: 1 };

describe("waitUntilOpenOnChain()", () => {
  it("returns immediately when every pending question is open", async () => {
    const flow = { loadProcess: jest.fn() };
    const onWait = jest.fn();

    const closed = await waitUntilOpenOnChain({
      flow,
      pending: [{ vocdoniQuestionId: "q1" }],
      loaded: remote({ q1: "READY", q2: "PAUSED" }),
      onWait,
      timings: fast
    });

    expect(closed).toEqual([]);
    expect(onWait).not.toHaveBeenCalled();
    expect(flow.loadProcess).not.toHaveBeenCalled();
  });

  it("re-reads the process until a paused question opens", async () => {
    const flow = { loadProcess: jest.fn() };
    flow.loadProcess.
      mockResolvedValueOnce(remote({ q1: "PAUSED" })).
      mockResolvedValueOnce(remote({ q1: "READY" }));
    const onWait = jest.fn();

    const closed = await waitUntilOpenOnChain({
      flow,
      pending: [{ vocdoniQuestionId: "q1" }],
      loaded: remote({ q1: "PAUSED" }),
      onWait,
      timings: fast
    });

    expect(closed).toEqual([]);
    expect(onWait).toHaveBeenCalledTimes(1);
    expect(flow.loadProcess).toHaveBeenCalledTimes(2);
  });

  it("gives back the questions still closed at the timeout", async () => {
    const flow = { loadProcess: jest.fn().mockResolvedValue(remote({ q1: "PAUSED" })) };

    const closed = await waitUntilOpenOnChain({
      flow,
      pending: [{ vocdoniQuestionId: "q1" }],
      loaded: remote({ q1: "PAUSED" }),
      onWait: jest.fn(),
      timings: fast
    });

    expect(closed).toEqual([{ vocdoniQuestionId: "q1" }]);
  });
});

describe("watchForNextQuestion()", () => {
  const respond = (...bodies) => {
    bodies.forEach((body) => {
      window.fetch.mockResolvedValueOnce({ json: () => Promise.resolve(body) });
    });
  };

  beforeEach(() => {
    window.fetch = jest.fn();
  });

  afterEach(() => {
    Reflect.deleteProperty(window, "fetch");
  });

  const flush = () => new Promise((resolve) => {
    setTimeout(resolve, 30);
  });

  it("reports the booth URL when a question this page did not render opens", async () => {
    respond(
      { url: "/booth", open_question_ids: ["1"] },
      { url: null, open_question_ids: [] },
      { url: "/booth", open_question_ids: ["2"] }
    );
    const onOpen = jest.fn();
    const onWaiting = jest.fn();

    watchForNextQuestion({ waitingUrl: "/waiting.json", renderedIds: ["1"], onWaiting, message: "Wait", onOpen, timings: fast });
    await flush();

    expect(onWaiting).toHaveBeenCalledWith("Wait");
    expect(onOpen).toHaveBeenCalledWith("/booth");
    expect(window.fetch).toHaveBeenCalledTimes(3);
  });

  it("stops and clears the notice once no question is left to open", async () => {
    respond({ url: "/receipt", open_question_ids: [] });
    const onOpen = jest.fn();
    const onWaiting = jest.fn();

    watchForNextQuestion({ waitingUrl: "/waiting.json", renderedIds: ["1"], onWaiting, message: "Wait", onOpen, timings: fast });
    await flush();

    expect(onOpen).not.toHaveBeenCalled();
    expect(onWaiting).toHaveBeenLastCalledWith("");
    expect(window.fetch).toHaveBeenCalledTimes(1);
  });

  it("can be stopped", async () => {
    window.fetch.mockResolvedValue({ json: () => Promise.resolve({ url: null, open_question_ids: [] }) });

    const stop = watchForNextQuestion({ waitingUrl: "/waiting.json", renderedIds: ["1"], onWaiting: jest.fn(), message: "Wait", onOpen: jest.fn(), timings: fast });
    stop();
    await flush();

    expect(window.fetch).not.toHaveBeenCalled();
  });
});

describe("mergeQuestions()", () => {
  it("appends new questions and marks the ones no longer open as closed", () => {
    const config = { questions: [{ questionId: "1" }, { questionId: "2" }] };

    mergeQuestions(config, { questions: [{ questionId: "2" }, { questionId: "3" }] });

    expect(config.questions).toEqual([
      { questionId: "1", closed: true },
      { questionId: "2", closed: false },
      { questionId: "3" }
    ]);
  });
});

describe("openInPlace()", () => {
  const liveCtx = (loaded) => ({
    config: { questions: [{ questionId: "1" }] },
    loadQuestions: jest.fn().mockResolvedValue(loaded),
    restart: jest.fn().mockResolvedValue()
  });

  it("adds the new questions and restarts the booth without leaving the page", async () => {
    const ctx = liveCtx({ questionIds: ["2"], config: { questions: [{ questionId: "1" }, { questionId: "2" }] } });
    const navigate = jest.fn();

    await openInPlace(ctx, "/booth", navigate);

    expect(ctx.loadQuestions).toHaveBeenCalledWith("/booth");
    expect(ctx.config.questions.map((question) => question.questionId)).toEqual(["1", "2"]);
    expect(ctx.restart).toHaveBeenCalled();
    expect(navigate).not.toHaveBeenCalled();
  });

  it("loads the page when there is no booth at the URL", async () => {
    const ctx = liveCtx(null);
    const navigate = jest.fn();

    await openInPlace(ctx, "/booth", navigate);

    expect(ctx.restart).not.toHaveBeenCalled();
    expect(navigate).toHaveBeenCalledWith("/booth");
  });

  it("loads the page when fetching the booth fails", async () => {
    const ctx = liveCtx(null);
    ctx.loadQuestions.mockRejectedValue(new Error("offline"));
    const navigate = jest.fn();

    await openInPlace(ctx, "/booth", navigate);

    expect(navigate).toHaveBeenCalledWith("/booth");
  });

  it("loads the page when the booth cannot add questions in place", async () => {
    const navigate = jest.fn();

    await openInPlace({ config: { questions: [] } }, "/booth", navigate);

    expect(navigate).toHaveBeenCalledWith("/booth");
  });
});

describe("createNextQuestionWatcher()", () => {
  beforeEach(() => {
    window.fetch = jest.fn().mockResolvedValue({ json: () => Promise.resolve({ url: "/booth", open_question_ids: ["1"] }) });
  });

  afterEach(() => {
    Reflect.deleteProperty(window, "fetch");
  });

  const ctxFor = (extra = {}) => ({
    config: {
      perQuestion: true,
      waitingUrl: "/waiting.json",
      perQuestionI18n: { waiting: "Wait" },
      questions: [{ questionId: "1", awaitingChain: true }]
    },
    progress: jest.fn(),
    ...extra
  });

  it("retries in place a question that is still waiting to open on chain", async () => {
    const ctx = ctxFor({
      loadQuestions: jest.fn().mockResolvedValue({ questionIds: [], config: { questions: [{ questionId: "1" }] } }),
      restart: jest.fn().mockResolvedValue()
    });

    createNextQuestionWatcher()(ctx);
    await new Promise((resolve) => {
      setTimeout(resolve, 30);
    });

    expect(ctx.loadQuestions).toHaveBeenCalledWith("/booth");
    expect(ctx.restart).toHaveBeenCalledTimes(1);
  });

  it("treats every rendered question as seen when the booth cannot add questions in place", async () => {
    jest.useFakeTimers();
    const ctx = ctxFor();

    createNextQuestionWatcher()(ctx);
    await jest.advanceTimersByTimeAsync(10);
    jest.clearAllTimers();
    jest.useRealTimers();

    expect(window.fetch).toHaveBeenCalledTimes(1);
    expect(ctx.progress).toHaveBeenCalledWith("Wait");
  });
});
