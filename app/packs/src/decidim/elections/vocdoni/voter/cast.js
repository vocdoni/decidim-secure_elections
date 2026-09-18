import { EphemeralSigner } from "@vocdoni/api-voting";
import { encodeChoices } from "src/decidim/elections/vocdoni/voter/ballot";
import { VoteError, ErrorCode, toVoteError } from "src/decidim/elections/vocdoni/voter/errors";

/**
 * Casting one question: ARCHITECTURE §3 steps 4 to 7.
 *
 * This is a plain function rather than a method so that `flow.js` stays within
 * a readable size. The auth token is handed in by the flow's closure for the
 * duration of the call and is never kept here.
 */

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Reads one question from the public per-question endpoint.
 *
 * @param {Object} client - the `@vocdoni/api-client` instance.
 * @param {string} processId - Mongo ObjectID of the process.
 * @param {string} questionId - question id inside the process.
 * @returns {Promise<Object>} the public question read.
 */
export const loadQuestion = async (client, processId, questionId) => {
  try {
    return await client.processes.getQuestion(processId, questionId);
  } catch (error) {
    throw toVoteError(error, ErrorCode.PROCESS_UNAVAILABLE);
  }
};

/**
 * For `secretUntilTheEnd` questions `encryptionKeys` is *absent* until the
 * keykeepers publish it. We poll until it appears and, if it never does, we
 * fail: casting a cleartext ballot as a fallback would silently destroy the
 * secrecy the voter was promised (ARCHITECTURE §3).
 *
 * @param {Object} params - polling context.
 * @param {Object} params.client - the api client.
 * @param {string} params.processId - the process id.
 * @param {Object} params.question - a question already read from the API.
 * @param {Function} [params.onWait] - called once when waiting starts.
 * @param {number} params.intervalMs - poll interval.
 * @param {number} params.timeoutMs - give up after this long.
 * @returns {Promise<Object>} the question, with `encryptionKeys` present.
 */
export const withEncryptionKeys = async ({ client, processId, question, onWait, intervalMs, timeoutMs }) => {
  const published = (candidate) =>
    Array.isArray(candidate.encryptionKeys) && candidate.encryptionKeys.length > 0;

  if (!question.secretUntilTheEnd || published(question)) {
    return question;
  }

  if (typeof onWait === "function") {
    onWait();
  }

  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    await sleep(intervalMs);

    const current = await loadQuestion(client, processId, question.id);

    if (published(current)) {
      return current;
    }
  }

  throw new VoteError(ErrorCode.KEYS_UNAVAILABLE);
};

/**
 * Signs and relays one question's ballot, then waits for the nullifier.
 *
 * The ephemeral signer is created here, used once and dropped when the function
 * returns. It is never returned to the caller, stored or logged.
 *
 * @param {Object} params - everything needed to cast one question.
 * @param {Object} params.client - the api client.
 * @param {Object} params.votingClient - the `@vocdoni/api-voting` client.
 * @param {string} params.processId - the process id.
 * @param {string} params.chainId - the chain id read from the process.
 * @param {string} params.authToken - the CSP token for this voter.
 * @param {string} params.questionId - question id inside the process.
 * @param {string} params.upstreamId - the question's vochain election id.
 * @param {number[]} params.selectedValues - the choice values picked.
 * @param {Function} [params.onProgress] - phase reporter for the UI.
 * @param {Object} params.timings - poll intervals and timeouts.
 * @returns {Promise<{nullifier: string}>} the vote receipt.
 */
export const castQuestion = async ({
  client,
  votingClient,
  processId,
  chainId,
  authToken,
  questionId,
  upstreamId,
  selectedValues,
  onProgress,
  timings
}) => {
  const report = (phase) => {
    if (typeof onProgress === "function") {
      onProgress(phase);
    }
  };

  report("preparing");

  const question = await withEncryptionKeys({
    client,
    processId,
    question: await loadQuestion(client, processId, questionId),
    onWait: () => report("waiting_keys"),
    intervalMs: timings.keyPollIntervalMs,
    timeoutMs: timings.keyPollTimeoutMs
  });

  // Encode before touching the CSP: a question's signing slot is consumed on a
  // successful `sign`, so an encoding failure must not burn it.
  const choices = encodeChoices(question, selectedValues);

  report("signing");

  const signer = new EphemeralSigner();
  let signed = null;

  try {
    signed = await client.processes.sign(processId, {
      authToken,
      // ARCHITECTURE §1: the QUESTION's upstreamId, never the process id.
      electionId: upstreamId,
      payload: signer.address
    });
  } catch (error) {
    throw toVoteError(error, ErrorCode.SIGN_REJECTED);
  }

  report("relaying");

  let jobId = null;

  try {
    jobId = await votingClient.vote({
      processId: upstreamId,
      chainId,
      choices,
      signer,
      cspSignature: signed.signature,
      cspWeight: signed.weight,
      ...(question.secretUntilTheEnd
        ? { encryptionKeys: question.encryptionKeys }
        : {})
    });
  } catch (error) {
    // The relay failed. Without a job id the vote almost certainly did not
    // land, but we cannot prove it — report "unconfirmed" rather than claim a
    // failure the voter might act on by voting twice.
    throw new VoteError(ErrorCode.RELAY_UNCONFIRMED, { cause: error });
  }

  report("confirming");

  let job = null;

  try {
    job = await client.jobs.waitFor(jobId, {
      intervalMs: timings.jobIntervalMs,
      timeoutMs: timings.jobTimeoutMs
    });
  } catch (error) {
    // Timed out or lost the connection while polling. The transaction is
    // already in flight: it may well be on chain.
    throw new VoteError(ErrorCode.RELAY_UNCONFIRMED, { cause: error });
  }

  if (!job || job.status !== "completed") {
    throw new VoteError(ErrorCode.RELAY_REJECTED, { cause: job });
  }

  const nullifier = job.result && job.result.voteID;

  if (!nullifier) {
    // Completed without a nullifier: the vote is on chain but we cannot show a
    // receipt for it. Still not a failure.
    throw new VoteError(ErrorCode.RELAY_UNCONFIRMED, { cause: job });
  }

  return { nullifier };
};
