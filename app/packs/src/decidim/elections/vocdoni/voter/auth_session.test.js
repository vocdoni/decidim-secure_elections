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

describe("a wrong one-time code", () => {
  const failing = async (error) => {
    const flow = await startFlow(["email"]);

    mockProcesses.authStep0.mockResolvedValue({ authToken: "tok" });
    mockProcesses.authStep1.mockRejectedValue(error);
    await flow.authenticate({ memberNumber: "2001" }, { contact: "carol@example.org" });

    return flow;
  };

  // Verified against staging: 401 / 40001 "challenge code do not match".
  it("is retryable and does not burn the session", async () => {
    const flow = await failing(apiError({ status: 401, code: 40001, message: "authentication required: challenge code do not match" }));

    await expect(flow.confirmOtp("000000")).rejects.toMatchObject({ code: ErrorCode.OTP_REJECTED });

    expect(flow.authenticated).toBe(true);
    expect(flow.verified).toBe(false);

    // Same token, so a second attempt costs nothing and needs no new code.
    mockProcesses.authStep1.mockResolvedValueOnce({ authToken: "tok" });
    await flow.confirmOtp("123456");
    expect(mockProcesses.authStep1).toHaveBeenLastCalledWith(PROCESS_ID, { authToken: "tok", authData: ["123456"] });
    expect(flow.verified).toBe(true);
  });

  it("is told apart from a session that is simply over", async () => {
    const flow = await failing(apiError({ status: 404, code: 40029, message: "census participant not found" }));

    await expect(flow.confirmOtp("000000")).rejects.toMatchObject({ code: ErrorCode.OTP_EXPIRED });
  });

  it("is told apart from the browser being offline", async () => {
    const flow = await failing(Object.assign(new TypeError("Failed to fetch"), { name: "TypeError" }));

    await expect(flow.confirmOtp("000000")).rejects.toMatchObject({ code: ErrorCode.NETWORK });
  });

  it("cannot be confirmed at all without a token", async () => {
    const flow = await startFlow(["email"]);

    await expect(flow.confirmOtp("123456")).rejects.toMatchObject({ code: ErrorCode.AUTH_REJECTED });
    expect(mockProcesses.authStep1).not.toHaveBeenCalled();
  });
});

describe("resending the code", () => {
  const pending = async (twoFaFields = ["email"], twoFa = { contact: "carol@example.org" }) => {
    const flow = await startFlow(twoFaFields);

    mockProcesses.authStep0.mockResolvedValue({ authToken: "tok" });
    await flow.authenticate({ memberNumber: "2001" }, twoFa);

    return flow;
  };

  // `resend` with only the token fails 40001 "invalid user email", so the value
  // collected at step 0 has to be replayed.
  it("replays the contact the voter gave, which resend requires", async () => {
    const flow = await pending();

    mockProcesses.resend.mockResolvedValue({ authToken: "tok" });

    await expect(flow.resendOtp()).resolves.toEqual({ channel: "email" });
    expect(mockProcesses.resend).toHaveBeenCalledWith(PROCESS_ID, {
      authToken: "tok",
      email: "carol@example.org"
    });
  });

  it("uses the chosen channel when the census offers both", async () => {
    const flow = await pending(["email", "phone"], { channel: "phone", contact: "+34600000000" });

    mockProcesses.resend.mockResolvedValue({});
    await expect(flow.resendOtp()).resolves.toEqual({ channel: "phone" });
    expect(mockProcesses.resend).toHaveBeenCalledWith(PROCESS_ID, {
      authToken: "tok",
      phone: "+34600000000"
    });
  });

  it("reports a delivery failure as its own state, not as a bad code", async () => {
    const flow = await pending();

    mockProcesses.resend.mockRejectedValue(apiError({ status: 500, code: 50001, message: "could not deliver" }));

    await expect(flow.resendOtp()).rejects.toMatchObject({ code: ErrorCode.OTP_RESEND_FAILED });
  });

  it("surfaces the CSP's own cooldown, with the seconds it asked for", async () => {
    const flow = await pending();

    mockProcesses.resend.mockRejectedValue(
      apiError({ status: 401, code: 40103, message: "attempt cooldown time not reached", data: { coolDownTime: 24588 } })
    );

    await expect(flow.resendOtp()).rejects.toMatchObject({
      code: ErrorCode.AUTH_COOLDOWN,
      details: { seconds: 25 }
    });
  });

  it("is refused once the session is verified, so no stray code goes out", async () => {
    const flow = await pending();

    mockProcesses.authStep1.mockResolvedValue({ authToken: "tok" });
    await flow.confirmOtp("123456");

    await expect(flow.resendOtp()).rejects.toMatchObject({ code: ErrorCode.OTP_RESEND_FAILED });
    expect(mockProcesses.resend).not.toHaveBeenCalled();
  });

  it("is refused before there is anything to resend", async () => {
    const flow = await startFlow(["email"]);

    await expect(flow.resendOtp()).rejects.toMatchObject({ code: ErrorCode.AUTH_REJECTED });
    expect(mockProcesses.resend).not.toHaveBeenCalled();
  });
});

describe("authStep0 rate limiting", () => {
  it("is a cooldown the voter can wait out, not a rejection of their details", async () => {
    const flow = await startFlow(["email"]);

    mockProcesses.authStep0.mockRejectedValue(
      apiError({ status: 401, code: 40103, message: "attempt cooldown time not reached", data: { coolDownTime: 24588 } })
    );

    await expect(flow.authenticate({ memberNumber: "2001" }, { contact: "carol@example.org" })).
      rejects.toMatchObject({ code: ErrorCode.AUTH_COOLDOWN, details: { seconds: 25 } });
  });

  it("falls back to a rejection when the CSP gives no wait time", async () => {
    const flow = await startFlow(["email"]);

    mockProcesses.authStep0.mockRejectedValue(apiError({ status: 400, code: 40005, message: "no contact information provided (email or phone)" }));

    await expect(flow.authenticate({ memberNumber: "2001" }, { contact: "" })).
      rejects.toMatchObject({ code: ErrorCode.AUTH_REJECTED });
  });
});
