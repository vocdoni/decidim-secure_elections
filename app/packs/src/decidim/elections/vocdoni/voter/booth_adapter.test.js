/* global jest */

/**
 * Tests for the `vocdoni` voting backend adapter used by Decidim's client-side booth.
 *
 * Tests focus on the partial-failure state machine (`cast` returning unconfirmed
 * and failed entries rather than throwing) and the partial-vote revisit path
 * (`prepare` returning `priorReceipts`+`pendingQuestionIds`).
 */

const mockFlow = {
  loadProcess: jest.fn(),
  twoFaChannels: jest.fn(() => []),
  authenticate: jest.fn(),
  confirmOtp: jest.fn(),
  resendOtp: jest.fn(),
  check: jest.fn(),
  castQuestion: jest.fn(),
  receipts: jest.fn()
};

jest.mock("src/decidim/elections/vocdoni/voter/flow", () => ({
  createVoterFlow: jest.fn(() => mockFlow)
}));

import { ErrorCode } from "src/decidim/elections/vocdoni/voter/errors";

// Load the adapter after the mocks are set up.
// The module registers on window.Decidim; we grab the adapter from there.
let adapter = null;

/**
 * Build an error object with the given VoteError code, without relying on the
 * VoteError class (avoids cross-module instanceof mismatches in jest).
 *
 * @param {string} code - one of ErrorCode.
 * @returns {Error} an error with the given code.
 */
const voteError = (code) => Object.assign(new Error(code), { code });

beforeEach(() => {
  jest.resetModules();
  Object.values(mockFlow).forEach((fn) => fn.mockReset && fn.mockReset());
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

describe("cast() — partial failure", () => {
  beforeEach(async () => {
    mockFlow.check.mockResolvedValue(checkResponse());
    // Run prepare to initialise flow and questionsByDecidimId.
    await adapter.prepare(makeCtx());
  });

  it("returns a confirmed receipt when all questions succeed", async () => {
    mockFlow.castQuestion.mockResolvedValue({ nullifier: "nullA" });
    const ctx = makeCtx();
    const ballot = [
      { questionId: "1", responseOptionIds: ["10"] },
      { questionId: "2", responseOptionIds: ["20"] }
    ];

    const result = await adapter.cast(ctx, ballot);

    expect(result.receipts).toHaveLength(2);
    expect(result.unconfirmed).toHaveLength(0);
    expect(result.failed).toHaveLength(0);
    expect(result.receipts[0].code).toBe("nullA");
  });

  it("puts RELAY_UNCONFIRMED errors into unconfirmed, not failed", async () => {
    mockFlow.castQuestion.
      mockResolvedValueOnce({ nullifier: "null1" }).
      mockRejectedValueOnce(voteError(ErrorCode.RELAY_UNCONFIRMED));

    const ctx = makeCtx();
    const ballot = [
      { questionId: "1", responseOptionIds: ["10"] },
      { questionId: "2", responseOptionIds: ["20"] }
    ];

    const result = await adapter.cast(ctx, ballot);

    expect(result.receipts).toHaveLength(1);
    expect(result.unconfirmed).toHaveLength(1);
    expect(result.failed).toHaveLength(0);
    expect(result.unconfirmed[0].questionId).toBe("2");
  });

  it("puts other errors into failed", async () => {
    mockFlow.castQuestion.
      mockResolvedValueOnce({ nullifier: "null1" }).
      mockRejectedValueOnce(voteError(ErrorCode.RELAY_REJECTED));

    const ctx = makeCtx();
    const ballot = [
      { questionId: "1", responseOptionIds: ["10"] },
      { questionId: "2", responseOptionIds: ["20"] }
    ];

    const result = await adapter.cast(ctx, ballot);

    expect(result.receipts).toHaveLength(1);
    expect(result.failed).toHaveLength(1);
    expect(result.unconfirmed).toHaveLength(0);
    expect(result.failed[0].questionId).toBe("2");
  });

  it("casts every question even when earlier ones fail", async () => {
    mockFlow.castQuestion.
      mockRejectedValueOnce(voteError(ErrorCode.RELAY_REJECTED)).
      mockResolvedValueOnce({ nullifier: "null2" });

    const ctx = makeCtx();
    const ballot = [
      { questionId: "1", responseOptionIds: ["10"] },
      { questionId: "2", responseOptionIds: ["20"] }
    ];

    const result = await adapter.cast(ctx, ballot);

    expect(mockFlow.castQuestion).toHaveBeenCalledTimes(2);
    expect(result.receipts).toHaveLength(1);
    expect(result.failed).toHaveLength(1);
    expect(result.receipts[0].questionId).toBe("2");
  });
});

describe("prepare() — partial vote revisit", () => {
  it("returns priorReceipts and pendingQuestionIds when only some questions are voted", async () => {
    mockFlow.check.mockResolvedValue(checkResponse({ q1: { hasVoted: true }, q2: { canVote: true } }));
    mockFlow.receipts.mockResolvedValue([{ questionId: "q1", nullifier: "null1", at: "2026-11-05T10:00:00Z" }]);

    const ctx = makeCtx();
    const result = await adapter.prepare(ctx);

    expect(result.canVote).toBe(true);
    expect(result.alreadyVoted).toBe(false);
    expect(result.priorReceipts).toHaveLength(1);
    expect(result.priorReceipts[0].questionId).toBe("1");
    expect(result.pendingQuestionIds).toEqual(["2"]);
  });

  it("returns alreadyVoted when all questions are voted", async () => {
    mockFlow.check.mockResolvedValue(checkResponse({ q1: { hasVoted: true }, q2: { hasVoted: true } }));
    mockFlow.receipts.mockResolvedValue([
      { questionId: "q1", nullifier: "null1", at: "2026-11-05T10:00:00Z" },
      { questionId: "q2", nullifier: "null2", at: "2026-11-05T10:01:00Z" }
    ]);

    const ctx = makeCtx();
    const result = await adapter.prepare(ctx);

    expect(result.canVote).toBe(false);
    expect(result.alreadyVoted).toBe(true);
    expect(result.receipts).toHaveLength(2);
  });
});

describe("recheck()", () => {
  beforeEach(async () => {
    mockFlow.check.mockResolvedValue(checkResponse());
    await adapter.prepare(makeCtx());
  });

  it("returns receipts for questions that now have a confirmed vote", async () => {
    mockFlow.receipts.mockResolvedValue([{ questionId: "q2", nullifier: "null2", at: "2026-11-05T10:00:00Z" }]);

    const ctx = makeCtx();
    const result = await adapter.recheck(ctx);

    expect(result.receipts).toHaveLength(1);
    expect(result.receipts[0].questionId).toBe("2");
    expect(result.receipts[0].code).toBe("null2");
  });

  it("returns an empty list when receipts() throws", async () => {
    mockFlow.receipts.mockRejectedValue(new Error("network"));

    const ctx = makeCtx();
    const result = await adapter.recheck(ctx);

    expect(result.receipts).toHaveLength(0);
  });
});

describe("prepare() — attested census", () => {
  const attestation = { attestation: { voterId: "ab" }, signature: "ef", contact: "alice@example.org", salt: "01" };

  beforeEach(() => {
    const meta = document.createElement("meta");
    meta.name = "csrf-token";
    meta.content = "csrf-1";
    document.head.replaceChildren(meta);
    mockFlow.check.mockResolvedValue(checkResponse());
  });

  afterEach(() => {
    Reflect.deleteProperty(window, "fetch");
  });

  it("authenticates with the attestation Decidim signs instead of credentials", async () => {
    window.fetch = jest.fn().mockResolvedValue({ ok: true, json: () => Promise.resolve(attestation) });
    const ctx = makeCtx();
    ctx.config.credentials = null;
    ctx.config.attestationUrl = "/processes/p/f/1/elections/7/vocdoni_attestation";

    await expect(adapter.prepare(ctx)).resolves.toEqual({ canVote: true, alreadyVoted: false });
    expect(window.fetch).toHaveBeenCalledWith("/processes/p/f/1/elections/7/vocdoni_attestation", {
      method: "POST",
      credentials: "same-origin",
      headers: { Accept: "application/json", "X-CSRF-Token": "csrf-1" }
    });
    expect(mockFlow.authenticate).toHaveBeenCalledWith(attestation, {});
  });

  it("stops before the CSP when Decidim refuses to sign", async () => {
    window.fetch = jest.fn().mockResolvedValue({ ok: false, status: 401 });
    const ctx = makeCtx();
    ctx.config.attestationUrl = "/attestation";
    ctx.config.i18n.errors.auth_rejected = "Rejected"; // eslint-disable-line camelcase

    await expect(adapter.prepare(ctx)).rejects.toThrow("Rejected");
    expect(mockFlow.authenticate).not.toHaveBeenCalled();
  });
});
