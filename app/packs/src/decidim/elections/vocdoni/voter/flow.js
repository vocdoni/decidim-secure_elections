import { VocdoniApiClient } from "@vocdoni/api-client";
import { VotingClient } from "@vocdoni/api-voting";
import { castQuestion, loadQuestion } from "src/decidim/elections/vocdoni/voter/cast";
import { ErrorCode, toVoteError } from "src/decidim/elections/vocdoni/voter/errors";
import { createAuthSession } from "src/decidim/elections/vocdoni/voter/auth_session";
import { channelsFor, offersChannelChoice, requiresOtp } from "src/decidim/elections/vocdoni/voter/two_fa";

/**
 * The voter flow, exactly as ARCHITECTURE §3 specifies it and as it was verified
 * end to end against a live election:
 *
 *   elections.get           - chainId (never `client.info()`)
 *   processes.authStep0     - authToken
 *   processes.authStep1     - only when the census declares twoFaFields
 *   processes.resend        - another one-time code, same token
 *   processes.check         - per-question eligibility (200 even when ineligible)
 *   processes.getQuestion   - ballotProtocol / encryptionKeys
 *   new EphemeralSigner()   - fresh per vote
 *   processes.sign          - electionId is the QUESTION's upstreamId
 *   votingClient.vote       - jobId
 *   jobs.waitFor            - job.result.voteID, the nullifier
 *
 * This module is deliberately DOM-free and returns plain data, so the flow can
 * be reasoned about (and tested) without a voting page around it.
 *
 * Secrets — the auth token, the one-time code and every ephemeral key — live in
 * closure variables that nothing outside this factory can reach. They are never
 * returned, never stringified, never stored (ARCHITECTURE §0.2 and §0.4).
 *
 * The CSP session — the auth token and the two-factor steps that verify it —
 * lives in `auth_session.js`. Every privileged call here (`check`, `sign`,
 * `vote`, `signInfo`) goes through its `requireVerifiedToken`, which is what
 * stops a token that never completed 2FA from reaching a ballot.
 */

const DEFAULTS = {
  jobIntervalMs: 1500,
  jobTimeoutMs: 90000,
  keyPollIntervalMs: 3000,
  keyPollTimeoutMs: 120000
};

/**
 * Builds a voter flow bound to one process.
 *
 * @param {Object} options - flow configuration.
 * @param {string} options.apiUrl - public SaaS API base URL.
 * @param {string} options.processId - Mongo ObjectID of the Vocdoni process.
 * @param {string} [options.chainId] - cached chain id; refreshed from the
 *   process read, which is the authoritative source.
 * @param {Object} [options.timings] - poll intervals and timeouts, see DEFAULTS.
 * @returns {Object} the flow API.
 */
export const createVoterFlow = ({ apiUrl, processId, chainId: cachedChainId = null, timings = {} } = {}) => {
  const client = new VocdoniApiClient({ apiUrl });
  const votingClient = new VotingClient({ client });
  const pollTimings = { ...DEFAULTS, ...timings };

  // --- private state -------------------------------------------------------
  let chainId = cachedChainId;
  let currentProcess = null;

  /**
   * Step 1 — the public process read. It is the only supported source of
   * `chainId`: a process published before a chain migration must still sign
   * against its own chain id.
   *
   * @returns {Promise<Object>} the process as the API returns it.
   */
  const loadProcess = async () => {
    try {
      currentProcess = await client.elections.get(processId);
    } catch (error) {
      throw toVoteError(error, ErrorCode.PROCESS_UNAVAILABLE);
    }

    chainId = currentProcess.chainId || chainId;

    return currentProcess;
  };

  /**
   * The census two-factor fields, as declared by the process itself. Empty (or
   * absent) means the census is auth-only and `authStep0` already returns a
   * verified token — ARCHITECTURE §3 step 2.
   *
   * @returns {string[]} the declared two-factor fields.
   */
  const twoFaFields = () => {
    const fields = currentProcess && currentProcess.census && currentProcess.census.twoFaFields;

    return Array.isArray(fields)
      ? fields
      : [];
  };

  /**
   * The credentials this census asks for, as the process itself declares them.
   * Empty when the process read carried no census, in which case the caller
   * falls back to what the server rendered.
   *
   * @returns {string[]} the declared `authFields`.
   */
  const authFields = () => {
    const fields = currentProcess && currentProcess.census && currentProcess.census.authFields;

    return Array.isArray(fields) && fields.length > 0
      ? fields
      : null;
  };

  /**
   * The delivery channels this census offers, `[]` for an auth-only one.
   *
   * @returns {string[]} `email` and/or `phone`.
   */
  const twoFaChannels = () => channelsFor(twoFaFields());

  // The CSP session. It owns the token, the `verified` bit and the two-factor
  // calls; the flow only forwards to it, so there is exactly one place where a
  // token can be created, upgraded or dropped.
  const session = createAuthSession({ client, processId, twoFaFields });

  /**
   * Step 3 — eligibility. `belongsToProcess: false` arrives with HTTP 200 and
   * is a legitimate answer, not an error: the caller renders it as a state.
   *
   * Gated on a *verified* token even though the API would answer a pending one:
   * a check that ran before 2FA would report a voter as eligible and tempt the
   * caller into opening the ballot.
   *
   * @returns {Promise<Object>} `{ belongsToProcess, weight, questions }`.
   */
  const check = async () => {
    const token = session.requireVerifiedToken();
    let response = null;

    try {
      response = await client.processes.check(processId, { authToken: token });
    } catch (error) {
      throw toVoteError(error, ErrorCode.AUTH_REJECTED);
    }

    return {
      belongsToProcess: Boolean(response && response.belongsToProcess),
      weight: response && response.weight,
      questions: (response && response.questions) || []
    };
  };

  /**
   * Steps 4 to 7 — cast one question. See `cast.js`.
   *
   * @param {Object} params - `{ questionId, upstreamId, selectedValues, onProgress }`.
   * @returns {Promise<{nullifier: string}>} the vote receipt.
   */
  // `async` so that a missing or unverified token rejects the returned promise
  // rather than throwing synchronously: the caller should not have to handle a
  // promise-returning function two different ways.
  const cast = async (params) => castQuestion({
    ...params,
    client,
    votingClient,
    processId,
    chainId,
    authToken: session.requireVerifiedToken(),
    timings: pollTimings
  });

  /**
   * Per-question receipts for everything this voter has already cast. This is
   * what makes the receipt page reachable on its own: the nullifier lives on
   * the server side of the CSP, so we can always fetch it back after
   * re-authenticating instead of stashing it in a URL or a session.
   *
   * @returns {Promise<Object[]>} `[{ questionId, upstreamId, nullifier, at }]`.
   */
  const receipts = async () => {
    const token = session.requireVerifiedToken();

    try {
      const response = await client.processes.signInfo(processId, { authToken: token });

      return (response && response.consumed) || [];
    } catch (error) {
      throw toVoteError(error, ErrorCode.UNKNOWN);
    }
  };

  return {
    loadProcess,
    authFields,
    twoFaFields,
    twoFaChannels,
    requiresOtp: () => requiresOtp(twoFaFields()),
    offersChannelChoice: () => offersChannelChoice(twoFaFields()),
    // The CSP session, forwarded verbatim.
    reset: session.reset,
    authenticate: session.authenticate,
    confirmOtp: session.confirmOtp,
    resendOtp: session.resendOtp,
    check,
    castQuestion: cast,
    loadQuestion: (questionId) => loadQuestion(client, processId, questionId),
    receipts,
    get chainId() {
      return chainId;
    },

    /**
     * A token exists — it may still be waiting for a one-time code.
     *
     * @returns {boolean} true once `authStep0` has succeeded.
     */
    get authenticated() {
      return session.authenticated;
    },

    /**
     * Every step the census demands is done. The only safe gate to vote on.
     *
     * @returns {boolean} true once the census is fully satisfied.
     */
    get verified() {
      return session.verified;
    }
  };
};

export default createVoterFlow;
