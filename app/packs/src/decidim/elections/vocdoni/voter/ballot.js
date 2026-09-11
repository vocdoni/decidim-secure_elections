import { encodeQuestionBallot } from "@vocdoni/ballot";
import { VoteError, ErrorCode } from "src/decidim/elections/vocdoni/voter/errors";

/**
 * Encodes the voter's selection for a single question into the on-chain ballot
 * array.
 *
 * Two paths, deliberately:
 *
 * 1. `ballotProtocol` present — delegate to `@vocdoni/ballot`. The protocol is
 *    what the vochain scrutinizer actually validates against, so when the API
 *    gives it to us it is the only correct source of truth (it is also the only
 *    way to get multichoice abstain padding right).
 *
 * 2. `ballotProtocol` absent — ARCHITECTURE §2.1 records that it comes back `null`
 *    for singlechoice questions, and §3 fixes the fallback encoding by named
 *    type. `@vocdoni/ballot` refuses to guess in that case (it throws for
 *    multichoice without a protocol), so we apply §3 by hand.
 *
 * @param {Object} question - the public question read (`processes.getQuestion`).
 * @param {number[]} selectedValues - the choice *values* the voter picked, in
 *   the order they appear in the question.
 * @returns {number[]} the ballot array.
 */
export const encodeChoices = (question, selectedValues) => {
  const values = Array.from(selectedValues);

  if (question && question.ballotProtocol) {
    try {
      return encodeQuestionBallot(question, values);
    } catch (error) {
      throw new VoteError(ErrorCode.BALLOT_UNSUPPORTED, { cause: error });
    }
  }

  const type = String(question && question.type || "").toLowerCase();
  const choices = Array.isArray(question && question.choices)
    ? question.choices
    : [];

  if (type === "singlechoice") {
    if (values.length !== 1) {
      throw new VoteError(ErrorCode.BALLOT_UNSUPPORTED);
    }
    return [values[0]];
  }

  if (type === "multichoice") {
    // ARCHITECTURE §3: one element per choice, 1 for selected and 0 for not.
    const picked = new Set(values);
    return choices.map((choice) => (picked.has(choice.value)
      ? 1
      : 0));
  }

  throw new VoteError(ErrorCode.BALLOT_UNSUPPORTED);
};

/**
 * Whether a selection satisfies the question's own constraints, checked before
 * anything is sent anywhere so the voter gets an inline message instead of a
 * server rejection.
 *
 * @param {Object} question - `{ type, minChoices, maxChoices }` as rendered by
 *   the server from the Decidim record.
 * @param {number[]} selectedValues - the choice values picked.
 * @returns {{valid: boolean, reason: (string|null)}} the validation outcome.
 */
export const validateSelection = (question, selectedValues) => {
  const count = selectedValues.length;

  if (question.type === "singlechoice") {
    return count === 1
      ? { valid: true, reason: null }
      : { valid: false, reason: "required" };
  }

  const min = Number.isFinite(question.minChoices) && question.minChoices > 0
    ? question.minChoices
    : 1;
  const max = Number.isFinite(question.maxChoices) && question.maxChoices > 0
    ? question.maxChoices
    : null;

  if (count < min) {
    return { valid: false, reason: "min_choices" };
  }

  if (max !== null && count > max) {
    return { valid: false, reason: "max_choices" };
  }

  return { valid: true, reason: null };
};
