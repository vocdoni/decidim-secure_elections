/* global jest */

// The SDK lives in this module's own package.json, not in the monorepo root, so
// the two clients are stubbed. What needs covering is *our* branching — the
// auth-only vs two-factor decision and the gate in front of the ballot — not
// the SDK's HTTP layer.
const mockProcesses = {
  authStep0: jest.fn(),
  authStep1: jest.fn(),
  resend: jest.fn(),
  check: jest.fn(),
  signInfo: jest.fn()
};
const mockElections = { get: jest.fn() };

jest.mock("@vocdoni/api-client", () => ({
  VocdoniApiClient: jest.fn(() => ({ elections: mockElections, processes: mockProcesses }))
}));

jest.mock("@vocdoni/api-voting", () => ({
  VotingClient: jest.fn(() => ({ vote: jest.fn() })),
  EphemeralSigner: jest.fn(() => ({ address: "0xabc" }))
}));

jest.mock("@vocdoni/ballot", () => ({ encodeQuestionBallot: jest.fn() }));

import { createVoterFlow } from "src/decidim/elections/vocdoni/voter/flow";
import { ErrorCode } from "src/decidim/elections/vocdoni/voter/errors";

const PROCESS_ID = "6a67ab45622d94e7c9a192a0";

/**
 * An error shaped like the ones `@vocdoni/api-client` throws, so the classifier
 * is exercised against the real body layout rather than a convenient one.
 *
 * @param {Object} spec - the API failure.
 * @param {number} spec.status - the HTTP status.
 * @param {number} spec.code - the backend error code.
 * @param {string} spec.message - the API's message.
 * @param {Object} [spec.data] - the error body's `data`, e.g. `coolDownTime`.
 * @returns {Error} the throwable.
 */
const apiError = ({ status, code, message, data = null }) => Object.assign(new Error(message), {
  status,
  code,
  body: data
    ? { error: message, code, data }
    : { error: message, code }
});

const newFlow = () => createVoterFlow({ apiUrl: "https://api.test", processId: PROCESS_ID });

/**
 * Loads a process whose census declares `twoFaFields`.
 *
 * @param {string[]} twoFaFields - the census `twoFaFields`.
 * @param {string[]} [authFields] - the census `authFields`.
 * @returns {Promise<Object>} the flow, with its process already read.
 */
const startFlow = async (twoFaFields, authFields = ["memberNumber"]) => {
  mockElections.get.mockResolvedValue({
    chainId: "vocdoni/LTS/1.2",
    census: { authFields, twoFaFields }
  });

  const flow = newFlow();

  await flow.loadProcess();

  return flow;
};

beforeEach(() => {
  Object.values(mockProcesses).forEach((fn) => fn.mockReset());
  mockElections.get.mockReset();
});

describe("an auth-only census", () => {
  it("gets a token that is verified on arrival and never touches authStep1", async () => {
    const flow = await startFlow([]);

    mockProcesses.authStep0.mockResolvedValue({ authToken: "tok" });

    await expect(flow.authenticate({ memberNumber: "1001" })).resolves.toEqual({
      needsOtp: false,
      channel: null
    });

    expect(mockProcesses.authStep0).toHaveBeenCalledWith(PROCESS_ID, { memberNumber: "1001" });
    expect(mockProcesses.authStep1).not.toHaveBeenCalled();
    expect(flow.verified).toBe(true);
  });

  it("sends no contact field, which the CSP would only ignore", async () => {
    const flow = await startFlow([]);

    mockProcesses.authStep0.mockResolvedValue({ authToken: "tok" });
    await flow.authenticate({ memberNumber: "1001" }, { channel: "email", contact: "carol@example.org" });

    expect(mockProcesses.authStep0).toHaveBeenCalledWith(PROCESS_ID, { memberNumber: "1001" });
  });

  it("can go straight to the ballot", async () => {
    const flow = await startFlow([]);

    mockProcesses.authStep0.mockResolvedValue({ authToken: "tok" });
    mockProcesses.check.mockResolvedValue({ belongsToProcess: true, weight: "01", questions: [] });

    await flow.authenticate({ memberNumber: "1001" });

    await expect(flow.check()).resolves.toMatchObject({ belongsToProcess: true });
    expect(mockProcesses.check).toHaveBeenCalledWith(PROCESS_ID, { authToken: "tok" });
  });

  it("treats a census the process does not describe as auth-only", async () => {
    mockElections.get.mockResolvedValue({ chainId: "vocdoni/LTS/1.2" });

    const flow = newFlow();

    await flow.loadProcess();
    mockProcesses.authStep0.mockResolvedValue({ authToken: "tok" });

    await expect(flow.authenticate({ memberNumber: "1001" })).resolves.toMatchObject({ needsOtp: false });
    expect(flow.verified).toBe(true);
  });
});

describe("a two-factor census", () => {
  it("reports the channels the census declares", async () => {
    expect((await startFlow(["email"])).twoFaChannels()).toEqual(["email"]);
    expect((await startFlow(["phone"])).twoFaChannels()).toEqual(["phone"]);
    expect((await startFlow(["email", "phone"])).twoFaChannels()).toEqual(["email", "phone"]);
    expect((await startFlow(["email", "phone"])).offersChannelChoice()).toBe(true);
    expect((await startFlow(["email"])).offersChannelChoice()).toBe(false);
  });

  it("sends the contact alongside the credentials, which authStep0 demands", async () => {
    const flow = await startFlow(["email"]);

    mockProcesses.authStep0.mockResolvedValue({ authToken: "tok" });

    await expect(flow.authenticate({ memberNumber: "2001" }, { contact: "carol@example.org" })).resolves.toEqual({
      needsOtp: true,
      channel: "email"
    });

    expect(mockProcesses.authStep0).toHaveBeenCalledWith(PROCESS_ID, {
      memberNumber: "2001",
      email: "carol@example.org"
    });
  });

  it("uses the channel the voter picked when the census offers both", async () => {
    const flow = await startFlow(["email", "phone"]);

    mockProcesses.authStep0.mockResolvedValue({ authToken: "tok" });

    await expect(flow.authenticate({ memberNumber: "2001" }, {
      channel: "phone",
      contact: "+34600000000"
    })).resolves.toEqual({ needsOtp: true, channel: "phone" });

    expect(mockProcesses.authStep0).toHaveBeenCalledWith(PROCESS_ID, {
      memberNumber: "2001",
      phone: "+34600000000"
    });
  });

  // The single most dangerous property of this API: `check` answers
  // `belongsToProcess: true` for a token that never went through authStep1.
  it("refuses every privileged call until the code is confirmed", async () => {
    const flow = await startFlow(["email"]);

    mockProcesses.authStep0.mockResolvedValue({ authToken: "tok" });
    mockProcesses.check.mockResolvedValue({ belongsToProcess: true, weight: "01", questions: [] });

    await flow.authenticate({ memberNumber: "2001" }, { contact: "carol@example.org" });

    expect(flow.authenticated).toBe(true);
    expect(flow.verified).toBe(false);

    await expect(flow.check()).rejects.toMatchObject({ code: ErrorCode.AUTH_REJECTED });
    await expect(flow.receipts()).rejects.toMatchObject({ code: ErrorCode.AUTH_REJECTED });
    await expect(flow.castQuestion({ questionId: "q", upstreamId: "u", selectedValues: [0] })).
      rejects.toMatchObject({ code: ErrorCode.AUTH_REJECTED });

    // Nothing was even attempted against the API.
    expect(mockProcesses.check).not.toHaveBeenCalled();
    expect(mockProcesses.signInfo).not.toHaveBeenCalled();
  });

  it("opens the ballot once authStep1 accepts the code", async () => {
    const flow = await startFlow(["email"]);

    mockProcesses.authStep0.mockResolvedValue({ authToken: "tok" });
    mockProcesses.authStep1.mockResolvedValue({ authToken: "tok" });
    mockProcesses.check.mockResolvedValue({ belongsToProcess: true, weight: "01", questions: [] });

    await flow.authenticate({ memberNumber: "2001" }, { contact: "carol@example.org" });
    await flow.confirmOtp("123456");

    expect(mockProcesses.authStep1).toHaveBeenCalledWith(PROCESS_ID, {
      authToken: "tok",
      authData: ["123456"]
    });
    expect(flow.verified).toBe(true);
    await expect(flow.check()).resolves.toMatchObject({ belongsToProcess: true });
  });

  // Staging echoes the same token back rather than minting a new one, so an
  // absent `authToken` on a 2xx must not read as a rejection.
  it("accepts a confirmation that echoes no new token", async () => {
    const flow = await startFlow(["email"]);

    mockProcesses.authStep0.mockResolvedValue({ authToken: "tok" });
    mockProcesses.authStep1.mockResolvedValue({});

    await flow.authenticate({ memberNumber: "2001" }, { contact: "carol@example.org" });
    await expect(flow.confirmOtp("123456")).resolves.toBeUndefined();
    expect(flow.verified).toBe(true);
  });

  it("adopts a replacement token when the CSP does mint one", async () => {
    const flow = await startFlow(["email"]);

    mockProcesses.authStep0.mockResolvedValue({ authToken: "tok" });
    mockProcesses.authStep1.mockResolvedValue({ authToken: "tok2" });
    mockProcesses.check.mockResolvedValue({ belongsToProcess: true, questions: [] });

    await flow.authenticate({ memberNumber: "2001" }, { contact: "carol@example.org" });
    await flow.confirmOtp("123456");
    await flow.check();

    expect(mockProcesses.check).toHaveBeenCalledWith(PROCESS_ID, { authToken: "tok2" });
  });

  it("drops a stale session when the voter identifies again", async () => {
    const flow = await startFlow(["email"]);

    mockProcesses.authStep0.mockResolvedValueOnce({ authToken: "tok" }).mockRejectedValueOnce(
      apiError({ status: 404, code: 40029, message: "census participant not found" })
    );

    await flow.authenticate({ memberNumber: "2001" }, { contact: "carol@example.org" });
    await expect(flow.authenticate({ memberNumber: "9999" }, { contact: "carol@example.org" })).rejects.toBeDefined();

    expect(flow.authenticated).toBe(false);
    expect(flow.verified).toBe(false);
  });
});

describe("reset", () => {
  it("clears the session so a retry starts from nothing", async () => {
    const flow = await startFlow(["email"]);

    mockProcesses.authStep0.mockResolvedValue({ authToken: "tok" });
    mockProcesses.authStep1.mockResolvedValue({ authToken: "tok" });

    await flow.authenticate({ memberNumber: "2001" }, { contact: "carol@example.org" });
    await flow.confirmOtp("123456");
    expect(flow.verified).toBe(true);

    flow.reset();

    expect(flow.authenticated).toBe(false);
    expect(flow.verified).toBe(false);
    await expect(flow.check()).rejects.toMatchObject({ code: ErrorCode.AUTH_REJECTED });
  });
});
