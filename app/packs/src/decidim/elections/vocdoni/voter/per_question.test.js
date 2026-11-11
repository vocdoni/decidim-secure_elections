/* global jest */
/* eslint-disable camelcase -- open_question_ids is the server's JSON key */

import { waitUntilOpenOnChain, watchForNextQuestion } from "src/decidim/elections/vocdoni/voter/per_question";

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

  it("navigates to the booth when a question this page did not render opens", async () => {
    respond(
      { url: "/booth", open_question_ids: ["1"] },
      { url: null, open_question_ids: [] },
      { url: "/booth", open_question_ids: ["2"] }
    );
    const navigate = jest.fn();
    const onWaiting = jest.fn();

    watchForNextQuestion({ waitingUrl: "/waiting.json", renderedIds: ["1"], onWaiting, message: "Wait", navigate, timings: fast });
    await flush();

    expect(onWaiting).toHaveBeenCalledWith("Wait");
    expect(navigate).toHaveBeenCalledWith("/booth");
    expect(window.fetch).toHaveBeenCalledTimes(3);
  });

  it("stops and clears the notice once no question is left to open", async () => {
    respond({ url: "/receipt", open_question_ids: [] });
    const navigate = jest.fn();
    const onWaiting = jest.fn();

    watchForNextQuestion({ waitingUrl: "/waiting.json", renderedIds: ["1"], onWaiting, message: "Wait", navigate, timings: fast });
    await flush();

    expect(navigate).not.toHaveBeenCalled();
    expect(onWaiting).toHaveBeenLastCalledWith("");
    expect(window.fetch).toHaveBeenCalledTimes(1);
  });

  it("can be stopped", async () => {
    window.fetch.mockResolvedValue({ json: () => Promise.resolve({ url: null, open_question_ids: [] }) });

    const stop = watchForNextQuestion({ waitingUrl: "/waiting.json", renderedIds: ["1"], onWaiting: jest.fn(), message: "Wait", navigate: jest.fn(), timings: fast });
    stop();
    await flush();

    expect(window.fetch).not.toHaveBeenCalled();
  });
});
