/* global jest */

/**
 * The adapter reports a cast to Decidim (see `cast_notification.js`) only when
 * at least one vote may have landed.
 */

const mockFlow = {
  loadProcess: jest.fn(),
  twoFaChannels: jest.fn(() => []),
  authenticate: jest.fn(),
  check: jest.fn(),
  castQuestion: jest.fn(),
  receipts: jest.fn()
};
const mockNotify = jest.fn();

jest.mock("src/decidim/elections/vocdoni/voter/flow", () => ({
  createVoterFlow: jest.fn(() => mockFlow)
}));
jest.mock("src/decidim/elections/vocdoni/voter/cast_notification", () => ({
  notifyVoteCast: (...args) => mockNotify(...args)
}));

const NOTIFY_URL = "/processes/p/f/1/elections/7/vocdoni_cast_notification";

let adapter = null;

const makeCtx = () => ({
  config: {
    processId: "abc123",
    apiUrl: "https://api.test",
    chainId: "vocdoni/test/1",
    castNotificationUrl: NOTIFY_URL,
    credentials: { memberNumber: "1" },
    contact: {},
    questions: [{ questionId: "1", vocdoniQuestionId: "q1", upstreamId: "u1", title: "Q1", choices: { "10": 0 } }],
    i18n: { status: {}, errors: { unknown: "Unknown" }, blocked: { "not_in_census": { body: "" }, "not_open": { body: "" } } }
  },
  progress: jest.fn(),
  showPanel: jest.fn()
});

const ballot = [{ questionId: "1", responseOptionIds: ["10"] }];

beforeEach(async () => {
  jest.resetModules();
  Object.values(mockFlow).forEach((fn) => fn.mockReset());
  mockNotify.mockReset();
  mockFlow.twoFaChannels.mockReturnValue([]);
  mockFlow.authenticate.mockResolvedValue({ needsOtp: false });
  mockFlow.loadProcess.mockResolvedValue({});
  mockFlow.check.mockResolvedValue({
    belongsToProcess: true,
    questions: [{ questionId: "q1", canVote: true, hasVoted: false }]
  });

  jest.isolateModules(() => {
    // eslint-disable-next-line global-require -- dynamic require is intentional here (jest.isolateModules)
    require("src/decidim/elections/vocdoni/voter/booth_adapter");
  });
  adapter = window.Decidim.votingBackends.vocdoni;
  await adapter.prepare(makeCtx());
});

describe("cast() — notifying Decidim", () => {
  it("notifies once after a confirmed cast", async () => {
    mockFlow.castQuestion.mockResolvedValue({ nullifier: "n1" });

    await adapter.cast(makeCtx(), ballot);

    expect(mockNotify).toHaveBeenCalledTimes(1);
    expect(mockNotify).toHaveBeenCalledWith(NOTIFY_URL);
  });

  it("notifies when the relay could not confirm, since the vote may have landed", async () => {
    mockFlow.castQuestion.mockRejectedValue(Object.assign(new Error("x"), { code: "relay_unconfirmed" }));

    await adapter.cast(makeCtx(), ballot);

    expect(mockNotify).toHaveBeenCalledTimes(1);
  });

  it("does not notify when every question failed", async () => {
    mockFlow.castQuestion.mockRejectedValue(Object.assign(new Error("x"), { code: "unknown" }));

    await adapter.cast(makeCtx(), ballot);

    expect(mockNotify).not.toHaveBeenCalled();
  });
});
