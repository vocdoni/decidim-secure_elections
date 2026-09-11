/* global jest, __dirname */

const mockProcesses = { authStep0: jest.fn(), authStep1: jest.fn(), resend: jest.fn(), check: jest.fn(), signInfo: jest.fn() };
const mockElections = { get: jest.fn() };

jest.mock("@vocdoni/api-client", () => ({
  VocdoniApiClient: jest.fn(() => ({ elections: mockElections, processes: mockProcesses, jobs: { waitFor: jest.fn() } }))
}));

jest.mock("@vocdoni/api-voting", () => ({
  VotingClient: jest.fn(() => ({ vote: jest.fn() })),
  EphemeralSigner: jest.fn(() => ({ address: "0xabc" }))
}));

jest.mock("@vocdoni/ballot", () => ({ encodeQuestionBallot: jest.fn() }));

import fs from "node:fs";
import path from "node:path";
import { createVotingPage } from "src/decidim/elections/vocdoni/voter/voting_page";
import strings from "../../../../../../public/vocdoni/locales/en.json";

/**
 * What `createVotingPage` does with a process read: it has to turn one public,
 * unauthenticated response into the whole voting page — the banner, the census form,
 * the ballot and the cast progress list — because there is no server left to
 * hand it any of that.
 */

// The shape verified against staging; the same document as
// `spec/fixtures/vocdoni/process.json`.
const PROCESS = {
  id: "6885f0c2c1a4e2f0b1d33a01",
  title: { default: "Board election 2026", ca: "Eleccions a la junta 2026" },
  description: { default: "<p>Pick the next chair.</p>" },
  startDate: "2026-07-27T14:51:08Z",
  endDate: "2026-07-29T14:51:08Z",
  chainId: "vocdoni/LTS/1.2",
  census: { authFields: ["memberNumber"], twoFaFields: ["email"], size: 3 },
  questions: [{
    id: "6885f0c2c1a4e2f0b1d33a02",
    upstreamId: "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
    title: { default: "Who should chair the board?" },
    choices: [{ title: { default: "Alice" }, value: 0 }, { title: { default: "Bob" }, value: 1 }],
    ballotProtocol: null,
    type: "singlechoice",
    secretUntilTheEnd: false,
    status: "ONGOING"
  }]
};

const SHELL = path.join(__dirname, "../../../../../../public/vocdoni/vote.html");

const visible = (node) => Boolean(node) && !node.hasAttribute("hidden");

const start = async (process = PROCESS, { locale = "en" } = {}) => {
  // eslint-disable-next-line no-sync -- a test fixture, reading one small file.
  const parsed = new DOMParser().parseFromString(fs.readFileSync(SHELL, "utf8"), "text/html");

  document.body.innerHTML = parsed.body.innerHTML;
  mockElections.get.mockResolvedValue(process);

  const page = createVotingPage({
    root: document.getElementById("js-vocdoni-vote"),
    params: { apiUrl: "https://api.example.org", processId: PROCESS.id, locale, exitUrl: "/back" },
    i18n: strings,
    locale,
    statusNode: document.getElementById("js-vocdoni-vote-status"),
    titleNode: document.getElementById("js-vocdoni-election-title"),
    exitNode: document.getElementById("js-vocdoni-election-exit")
  });

  await page.start();

  return page;
};

afterEach(() => {
  jest.clearAllMocks();
  document.body.innerHTML = "";
});

describe("starting the voting page", () => {
  it("reads the process once, publicly, and lands on the census step", async () => {
    await start();

    expect(mockElections.get).toHaveBeenCalledWith(PROCESS.id);
    expect(visible(document.getElementById("js-vocdoni-step-auth"))).toBe(true);
    expect(visible(document.getElementById("js-vocdoni-step-loading"))).toBe(false);
  });

  // "Loading the election…" describes work that is over by the time the form is
  // on screen; leaving it above the stepper makes the live region a liar.
  it("clears the status line once the identification form is drawn", async () => {
    await start();

    expect(document.getElementById("js-vocdoni-vote-status").textContent).toBe("");
  });

  it("names the election in the banner and in the page title", async () => {
    await start();

    expect(document.getElementById("js-vocdoni-election-title").textContent).toBe("Board election 2026");
    expect(document.title).toContain("Board election 2026");
  });

  it("resolves the API's language maps against the locale it is speaking", async () => {
    await start(PROCESS, { locale: "ca" });

    expect(document.getElementById("js-vocdoni-election-title").textContent).toBe("Eleccions a la junta 2026");
  });

  it("offers the way back the link gave it", async () => {
    await start();

    expect(document.querySelector("#js-vocdoni-election-exit a").getAttribute("href")).toBe("/back");
  });

  // The census on the live process wins over anything a link or a cached page
  // might have said, which is what makes a census edited after the fact safe.
  it("builds the form from the census on the process, two-factor included", async () => {
    await start();

    expect(Array.from(document.querySelectorAll("[data-auth-field]")).map((input) => input.dataset.authField)).
      toEqual(["memberNumber"]);
    expect(visible(document.getElementById("js-vocdoni-auth-twofa"))).toBe(true);
    expect(visible(document.querySelector("[data-twofa-field-wrapper='email']"))).toBe(true);
    // One channel on offer, so there is nothing to choose.
    expect(visible(document.getElementById("js-vocdoni-auth-channel"))).toBe(false);
  });

  it("builds the ballot and one cast-progress row per question", async () => {
    await start();

    expect(document.querySelectorAll("[data-question-index]")).toHaveLength(1);
    expect(document.querySelectorAll("[data-question-index='0'] input[type='radio']")).toHaveLength(2);
    expect(document.querySelectorAll("[data-submit-question-index]")).toHaveLength(1);
  });

  it("keeps the upstream id apart, ready for check to confirm it per voter", async () => {
    const { state } = await start();

    expect(state.questions[0].processUpstreamId).toBe(PROCESS.questions[0].upstreamId);
    expect(state.questions[0].upstreamId).toBeNull();
  });

  it("warns up front when voting is not open, without hiding the receipt route", async () => {
    await start({ ...PROCESS, status: "ENDED" });

    expect(visible(document.getElementById("js-vocdoni-auth-closed-notice"))).toBe(true);
    expect(visible(document.getElementById("js-vocdoni-step-auth"))).toBe(true);
  });

  it("says nothing about a closed election when it is open", async () => {
    await start({ ...PROCESS, endDate: "2099-01-01T00:00:00Z" });

    expect(visible(document.getElementById("js-vocdoni-auth-closed-notice"))).toBe(false);
  });

  it("shows the terminal error state when the process cannot be read", async () => {
    // eslint-disable-next-line no-sync -- a test fixture, reading one small file.
    const parsed = new DOMParser().parseFromString(fs.readFileSync(SHELL, "utf8"), "text/html");

    document.body.innerHTML = parsed.body.innerHTML;
    mockElections.get.mockRejectedValue(new Error("boom"));

    await createVotingPage({
      root: document.getElementById("js-vocdoni-vote"),
      params: { apiUrl: "https://api.example.org", processId: PROCESS.id },
      i18n: strings,
      locale: "en",
      statusNode: document.getElementById("js-vocdoni-vote-status")
    }).start();

    expect(visible(document.getElementById("js-vocdoni-step-error"))).toBe(true);
    expect(document.getElementById("js-vocdoni-error-message").textContent).
      toBe(strings.errors.process_unavailable);
    // The error is its own alert; the status line stops claiming to be loading.
    expect(document.getElementById("js-vocdoni-vote-status").textContent).toBe("");
  });
});
