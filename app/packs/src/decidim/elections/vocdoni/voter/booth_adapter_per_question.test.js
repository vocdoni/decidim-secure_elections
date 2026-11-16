/* global jest */

/**
 * Tests for the `vocdoni` voting backend adapter used by Decidim's client-side booth.
 *
 * Per-question elections: `prepare` holds the ballot until the open questions
 * are READY on chain and, once they are cast, watches for the next one.
 */

const mockFlow = {
  loadProcess: jest.fn(),
  twoFaChannels: jest.fn(() => []),
  authenticate: jest.fn(),
  confirmOtp: jest.fn(),
  resendOtp: jest.fn(),
  check: jest.fn(),
  castQuestion: jest.fn(),
  receipts: jest.fn(),
  verified: false
};

jest.mock("src/decidim/elections/vocdoni/voter/flow", () => ({
  createVoterFlow: jest.fn(() => mockFlow)
}));

// Load the adapter after the mocks are set up.
// The module registers on window.Decidim; we grab the adapter from there.
let adapter = null;

beforeEach(() => {
  jest.resetModules();
  Object.values(mockFlow).forEach((fn) => fn.mockReset && fn.mockReset());
  mockFlow.verified = false;
  mockFlow.twoFaChannels.mockReturnValue([]);
  mockFlow.authenticate.mockResolvedValue({ needsOtp: false });
  mockFlow.loadProcess.mockResolvedValue({});

  // Re-import to get a fresh adapter instance.
  jest.isolateModules(() => {
    // eslint-disable-next-line global-require -- dynamic require is intentional here (jest.isolateModules)
    require("src/decidim/elections/vocdoni/voter/booth_adapter");
  });
  adapter = window.Decidim && window.Decidim.votingBackends && window.Decidim.votingBackends.vocdoni;
});

const makeCtx = () => ({
  config: {
    processId: "abc123",
    apiUrl: "https://api.test",
    chainId: "vocdoni/test/1",
    explorerUrl: "https://explorer.test",
    credentials: { memberNumber: "1" },
    contact: { email: "alice@example.org" },
    questions: [
      {
        questionId: "1",
        vocdoniQuestionId: "q1",
        upstreamId: "u1",
        title: "Q1",
        choices: { "10": 0, "11": 1 }
      },
      {
        questionId: "2",
        vocdoniQuestionId: "q2",
        upstreamId: "u2",
        title: "Q2",
        choices: { "20": 0, "21": 1 }
      }
    ],
    // i18n keys mirror Rails YAML structure — snake_case by convention.
    /* eslint-disable camelcase */
    i18n: {
      not_ready: "Not ready",
      status: { loading: "Loading…", authenticating: "Auth…", checking: "Checking…" },
      errors: { relay_unconfirmed: "Unconfirmed", unknown: "Unknown error" },
      blocked: {
        not_in_census: { body: "Not in census" },
        not_open: { body: "Not open" }
      },
      otp: {},
      receipt: { open: "Check my receipt" }
    }
    /* eslint-enable camelcase */
  },
  progress: jest.fn(),
  error: jest.fn(),
  showPanel: jest.fn()
});

// Simulates the check() response with per-question status.
const checkResponse = ({ q1 = {}, q2 = {} } = {}) => ({
  belongsToProcess: true,
  questions: [
    { questionId: "q1", canVote: q1.canVote !== false, hasVoted: Boolean(q1.hasVoted) },
    { questionId: "q2", canVote: q2.canVote !== false, hasVoted: Boolean(q2.hasVoted) }
  ]
});

describe("prepare() — per-question election", () => {
  const perQuestionCtx = () => {
    const ctx = makeCtx();
    ctx.config.perQuestion = true;
    ctx.config.waitingUrl = "/waiting.json";
    // eslint-disable-next-line camelcase -- mirrors the Rails i18n key
    ctx.config.perQuestionI18n = { opening: "Opening…", waiting: "Wait", not_open: "Not open yet" };

    return ctx;
  };

  beforeEach(() => {
    // eslint-disable-next-line camelcase -- the server's JSON key
    window.fetch = jest.fn().mockResolvedValue({ json: () => Promise.resolve({ url: null, open_question_ids: [] }) });
  });

  afterEach(() => {
    Reflect.deleteProperty(window, "fetch");
  });

  it("lets the voter in once the open questions are READY on chain", async () => {
    mockFlow.loadProcess.mockResolvedValue({ questions: [{ id: "q1", status: "READY" }, { id: "q2", status: "READY" }] });
    mockFlow.check.mockResolvedValue(checkResponse());

    const state = await adapter.prepare(perQuestionCtx());

    expect(state).toEqual({ canVote: true, alreadyVoted: false });
  });

  it("refuses the ballot while the questions are still paused on chain", async () => {
    jest.useFakeTimers();
    mockFlow.loadProcess.mockResolvedValue({ questions: [{ id: "q1", status: "PAUSED" }, { id: "q2", status: "PAUSED" }] });
    mockFlow.check.mockResolvedValue(checkResponse());
    const ctx = perQuestionCtx();

    const pending = adapter.prepare(ctx);
    await jest.advanceTimersByTimeAsync(130000);
    const state = await pending;
    jest.useRealTimers();

    expect(ctx.progress).toHaveBeenCalledWith("Opening…");
    expect(state).toEqual({ canVote: false, alreadyVoted: false, message: "Not open yet" });
  });

  it("watches for the next question when every open question is cast", async () => {
    mockFlow.loadProcess.mockResolvedValue({ questions: [{ id: "q1", status: "READY" }, { id: "q2", status: "READY" }] });
    mockFlow.check.mockResolvedValue(checkResponse({ q1: { hasVoted: true }, q2: { hasVoted: true } }));
    mockFlow.receipts.mockResolvedValue([]);

    const state = await adapter.prepare(perQuestionCtx());
    await new Promise((resolve) => {
      setTimeout(resolve, 10);
    });

    expect(state.alreadyVoted).toBe(true);
    expect(window.fetch).toHaveBeenCalledWith("/waiting.json", expect.any(Object));
  });
});

describe("prepare() — again on the same page, for a question opened in place", () => {
  const ready = { questions: [{ id: "q1", status: "READY" }, { id: "q2", status: "READY" }] };

  beforeEach(() => {
    mockFlow.loadProcess.mockResolvedValue(ready);
    mockFlow.receipts.mockResolvedValue([{ questionId: "q1", nullifier: "0xaa" }]);
    mockFlow.authenticate.mockImplementation(async () => {
      mockFlow.verified = true;

      return { needsOtp: false };
    });
  });

  it("reuses the verified CSP session instead of signing in again", async () => {
    const ctx = makeCtx();
    mockFlow.check.mockResolvedValueOnce(checkResponse({ q2: { canVote: false } }));
    await adapter.prepare(ctx);

    mockFlow.check.mockResolvedValueOnce(checkResponse({ q1: { hasVoted: true } }));
    const state = await adapter.prepare(ctx);

    expect(mockFlow.authenticate).toHaveBeenCalledTimes(1);
    expect(mockFlow.check).toHaveBeenCalledTimes(2);
    expect(state.pendingQuestionIds).toEqual(["2"]);
    expect(state.priorReceipts.map((receipt) => receipt.code)).toEqual(["0xaa"]);
  });

  it("signs in again when the CSP no longer takes the reused token", async () => {
    const ctx = makeCtx();
    mockFlow.check.mockResolvedValueOnce(checkResponse());
    await adapter.prepare(ctx);

    mockFlow.check.
      mockRejectedValueOnce(Object.assign(new Error("invalid token"), { code: "auth_rejected" })).
      mockResolvedValueOnce(checkResponse({ q1: { hasVoted: true } }));
    const state = await adapter.prepare(ctx);

    expect(mockFlow.authenticate).toHaveBeenCalledTimes(2);
    expect(state.pendingQuestionIds).toEqual(["2"]);
  });

  it("does not offer a question whose results are out", async () => {
    const ctx = makeCtx();
    ctx.config.questions[0].closed = true;
    mockFlow.check.mockResolvedValueOnce(checkResponse());

    await adapter.prepare(ctx);

    expect(ctx.config.questions.map((question) => question.canVote)).toEqual([false, true]);
  });
});
