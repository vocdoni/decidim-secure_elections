import { isVotingOpen, localizer, normalizeProcess } from "src/decidim/elections/vocdoni/voter/process";

// The shape verified against staging and recorded in `spec/fixtures/vocdoni/process.json`.
const PROCESS = {
  id: "6885f0c2c1a4e2f0b1d33a01",
  title: { default: "Board election 2026", en: "Board election 2026", ca: "Eleccions a la junta 2026" },
  description: { default: "<p>Pick the next chair.</p>" },
  startDate: "2026-07-27T14:51:08Z",
  endDate: "2026-07-29T14:51:08Z",
  chainId: "vocdoni/LTS/1.2",
  census: { authFields: ["memberNumber"], twoFaFields: [], weighted: false, size: 3 },
  questions: [
    {
      id: "6885f0c2c1a4e2f0b1d33a02",
      upstreamId: "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
      title: { default: "Who should chair the board?", ca: "Qui hauria de presidir?" },
      choices: [
        { title: { default: "Alice" }, value: 0 },
        { title: { default: "Bob" }, value: 1 }
      ],
      ballotProtocol: null,
      type: "singlechoice",
      secretUntilTheEnd: false,
      status: "ONGOING"
    }
  ]
};

const DURING = Date.parse("2026-07-28T00:00:00Z");

describe("localizer", () => {
  const resolve = localizer("ca");

  it("prefers the requested locale", () => {
    expect(resolve(PROCESS.title)).toBe("Eleccions a la junta 2026");
  });

  it("falls back to the base language, then to `default`", () => {
    expect(localizer("pt-BR")(PROCESS.title)).toBe("Board election 2026");
    expect(resolve({ default: "Only default" })).toBe("Only default");
  });

  // An election translated only into Catalan should still be readable rather
  // than blank.
  it("falls back to any translation at all before giving up", () => {
    expect(localizer("en")({ ca: "Només català" })).toBe("Només català");
  });

  it("passes a plain string through and turns nothing into an empty string", () => {
    expect(resolve("Plain")).toBe("Plain");
    expect(resolve(null)).toBe("");
  });
});

describe("normalizeProcess", () => {
  const process = normalizeProcess(PROCESS, "en");

  it("carries the census the voting page must branch on", () => {
    expect(process.authFields).toEqual(["memberNumber"]);
    expect(process.twoFaFields).toEqual([]);
  });

  it("localizes the questions and their choices", () => {
    expect(process.questions[0].title).toBe("Who should chair the board?");
    expect(process.questions[0].choices).toEqual([
      { value: 0, title: "Alice" },
      { value: 1, title: "Bob" }
    ]);
  });

  // ARCHITECTURE §1: the id used to sign is the question's `upstreamId`, and it is
  // kept apart from the id used to address the question inside the process.
  it("keeps the question id and the upstream id apart", () => {
    expect(process.questions[0].vocdoniQuestionId).toBe("6885f0c2c1a4e2f0b1d33a02");
    expect(process.questions[0].processUpstreamId).toMatch(/^c5d2460186/);
  });

  it("defaults a singlechoice question to exactly one selection", () => {
    expect(process.questions[0].minChoices).toBe(1);
    expect(process.questions[0].maxChoices).toBe(1);
  });

  it("reads the multichoice bounds from typeSetup, and bounds the maximum by the choices", () => {
    const multi = normalizeProcess({
      questions: [
        { id: "a", type: "multichoice", typeSetup: { minChoices: 2, maxChoices: 3 }, choices: PROCESS.questions[0].choices },
        { id: "b", type: "multichoice", choices: PROCESS.questions[0].choices }
      ]
    }, "en").questions;

    expect([multi[0].minChoices, multi[0].maxChoices]).toEqual([2, 3]);
    expect([multi[1].minChoices, multi[1].maxChoices]).toEqual([1, 2]);
  });

  it("drops a question with no id, which nothing could be cast against", () => {
    expect(normalizeProcess({ questions: [{ title: "orphan" }] }, "en").questions).toEqual([]);
  });

  it("survives a process read with nothing in it", () => {
    const empty = normalizeProcess(null, "en");

    expect(empty.questions).toEqual([]);
    expect(empty.authFields).toEqual([]);
  });
});

describe("isVotingOpen", () => {
  it("is true inside the window with a live question", () => {
    expect(isVotingOpen(normalizeProcess(PROCESS, "en"), DURING)).toBe(true);
  });

  it("is false before the start and after the end", () => {
    const process = normalizeProcess(PROCESS, "en");

    expect(isVotingOpen(process, Date.parse("2026-07-01T00:00:00Z"))).toBe(false);
    expect(isVotingOpen(process, Date.parse("2026-08-01T00:00:00Z"))).toBe(false);
  });

  it("is false when the process itself is paused, ended or canceled", () => {
    ["PAUSED", "ENDED", "RESULTS", "CANCELED"].forEach((status) => {
      expect(isVotingOpen(normalizeProcess({ ...PROCESS, status }, "en"), DURING)).toBe(false);
    });
  });

  it("is false when every question is closed", () => {
    const closed = { ...PROCESS, questions: [{ ...PROCESS.questions[0], status: "ENDED" }] };

    expect(isVotingOpen(normalizeProcess(closed, "en"), DURING)).toBe(false);
  });

  // Permissive on purpose: `processes.check` is the authority, so an unknown
  // status costs an honest "nothing is open for you" one screen later rather
  // than locking a live election out of its own voting page.
  it("is true when a question reports no status at all", () => {
    const { status, ...stateless } = PROCESS.questions[0];
    const unknown = { ...PROCESS, questions: [stateless] };

    expect(status).toBe("ONGOING");
    expect(isVotingOpen(normalizeProcess(unknown, "en"), DURING)).toBe(true);
  });
});
