/* global jest */

// The encoder is stubbed. That is deliberate: what needs covering is *our*
// branch — ARCHITECTURE §3's fallback for questions whose `ballotProtocol` comes
// back null (§2.1) — not the SDK's own encoding, which has its own tests.
const mockEncodeQuestionBallot = jest.fn();

jest.mock("@vocdoni/ballot", () => ({ encodeQuestionBallot: (...args) => mockEncodeQuestionBallot(...args) }));

import { encodeChoices, validateSelection } from "src/decidim/elections/vocdoni/voter/ballot";
import { VoteError } from "src/decidim/elections/vocdoni/voter/errors";

const choices = [
  { title: { default: "Yes" }, value: 0 },
  { title: { default: "No" }, value: 1 },
  { title: { default: "Abstain" }, value: 2 }
];

describe("encodeChoices", () => {
  beforeEach(() => {
    mockEncodeQuestionBallot.mockReset();
  });

  describe("when the question carries a ballotProtocol", () => {
    it("delegates to @vocdoni/ballot, which is what the chain validates against", () => {
      mockEncodeQuestionBallot.mockReturnValue([1, 3]);

      const question = { type: "multichoice", choices, ballotProtocol: { maxCount: 2, maxValue: 3 } };

      expect(encodeChoices(question, [1])).toEqual([1, 3]);
      expect(mockEncodeQuestionBallot).toHaveBeenCalledWith(question, [1]);
    });

    it("wraps an encoder failure into a VoteError", () => {
      mockEncodeQuestionBallot.mockImplementation(() => {
        throw new Error("nope");
      });

      const question = { type: "multichoice", choices, ballotProtocol: { maxCount: 2, maxValue: 1 } };

      expect(() => encodeChoices(question, [0, 1, 2])).toThrow(VoteError);
    });
  });

  describe("when ballotProtocol is null", () => {
    it("encodes a single choice as the chosen value", () => {
      expect(encodeChoices({ type: "singlechoice", choices }, [2])).toEqual([2]);
      expect(mockEncodeQuestionBallot).not.toHaveBeenCalled();
    });

    it("rejects a single choice question without exactly one selection", () => {
      expect(() => encodeChoices({ type: "singlechoice", choices }, [])).toThrow(VoteError);
      expect(() => encodeChoices({ type: "singlechoice", choices }, [0, 1])).toThrow(VoteError);
    });

    it("encodes a multiple choice as one 1/0 element per choice", () => {
      expect(encodeChoices({ type: "multichoice", choices }, [0, 2])).toEqual([1, 0, 1]);
    });

    it("encodes an empty multiple choice selection as all zeroes", () => {
      expect(encodeChoices({ type: "multichoice", choices }, [])).toEqual([0, 0, 0]);
    });

    it("refuses to guess for an unknown type", () => {
      expect(() => encodeChoices({ type: "budget", choices }, [0])).toThrow(VoteError);
    });
  });
});

describe("validateSelection", () => {
  it("requires exactly one answer for a single choice question", () => {
    const question = { type: "singlechoice" };

    expect(validateSelection(question, [1])).toEqual({ valid: true, reason: null });
    expect(validateSelection(question, [])).toEqual({ valid: false, reason: "required" });
    expect(validateSelection(question, [0, 1])).toEqual({ valid: false, reason: "required" });
  });

  it("enforces the multiple choice bounds", () => {
    const question = { type: "multichoice", minChoices: 2, maxChoices: 3 };

    expect(validateSelection(question, [0, 1])).toEqual({ valid: true, reason: null });
    expect(validateSelection(question, [0])).toEqual({ valid: false, reason: "min_choices" });
    expect(validateSelection(question, [0, 1, 2, 3])).toEqual({ valid: false, reason: "max_choices" });
  });

  it("defaults to at least one answer when no bounds are configured", () => {
    const question = { type: "multichoice", minChoices: null, maxChoices: null };

    expect(validateSelection(question, [])).toEqual({ valid: false, reason: "min_choices" });
    expect(validateSelection(question, [0, 1, 2])).toEqual({ valid: true, reason: null });
  });
});
