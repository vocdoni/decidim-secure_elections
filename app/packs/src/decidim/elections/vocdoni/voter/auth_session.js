import { ApiErrorCode, VoteError, ErrorCode, apiErrorCode, toVoteError, toCooldownError } from "src/decidim/elections/vocdoni/voter/errors";
import { channelsFor, requiresOtp } from "src/decidim/elections/vocdoni/voter/two_fa";

/**
 * The voter's CSP session: the auth token and everything that can change it.
 *
 * ## Why the token carries a `verified` bit
 *
 * `processes.check` answers `belongsToProcess: true` for a token that has not
 * been through `authStep1` yet — verified against staging, and the single most
 * dangerous property of this API. Anything gated on "did check succeed" would
 * therefore be gated on nothing at all. This session tracks verification
 * itself, from the one source that is authoritative before any call is made:
 * `census.twoFaFields` on the public process read.
 *
 * The token, the attested contact and the one-time code live in closure variables that
 * nothing outside this factory can reach. They are never returned, never
 * stringified and never stored (ARCHITECTURE §0.2 and §0.4).
 */

/**
 * Builds a session bound to one process.
 *
 * @param {Object} options - session dependencies.
 * @param {Object} options.client - the `@vocdoni/api-client` instance.
 * @param {string} options.processId - Mongo ObjectID of the Vocdoni process.
 * @param {Function} options.twoFaFields - reads `census.twoFaFields` off the
 *   currently loaded process. A function, not a value: the process is read
 *   after the session is built.
 * @returns {Object} the session API.
 */
export const createAuthSession = ({ client, processId, twoFaFields }) => {
  let authToken = null;
  // False for a token from `authStep0` on a 2FA census: it exists, it even
  // passes `check`, but it may not vote until `authStep1` accepts a code.
  let verified = false;
  // The channel the code goes to, and the contact and salt of the attestation:
  // `resend` replays them, and the CSP checks them against the contactHash it
  // signed. In memory for the life of the page, like every other credential here.
  let channel = null;
  let attestedContact = null;

  /**
   * A token exists at all — enough to confirm a one-time code, nothing more.
   *
   * @returns {string} the token.
   */
  const requirePendingToken = () => {
    if (!authToken) {
      throw new VoteError(ErrorCode.AUTH_REJECTED);
    }

    return authToken;
  };

  /**
   * A token that has completed every step the census demands. This is the gate
   * in front of every call that can move a vote.
   *
   * @returns {string} the token.
   */
  const requireVerifiedToken = () => {
    if (!authToken || !verified) {
      throw new VoteError(ErrorCode.AUTH_REJECTED);
    }

    return authToken;
  };

  /**
   * Drops every trace of the current identification. Called before a fresh
   * attempt so a retry can never reuse a half-authenticated token.
   *
   * @returns {void} nothing.
   */
  const reset = () => {
    authToken = null;
    verified = false;
    channel = null;
    attestedContact = null;
  };

  /**
   * Step 2 — identify the participant with the body Decidim signed:
   * `attestation`, `signature` and, with 2FA, the `contact` and `salt` that
   * open its contactHash. It goes to `authStep0` as it is.
   *
   * @param {Object} attested - the attestation body from Decidim.
   * @returns {Promise<{needsOtp: boolean, channel: string|null}>} where the
   *   voter goes next.
   */
  const authenticate = async (attested) => {
    // A stale token from an abandoned attempt must never survive a new one.
    reset();

    const fields2Fa = twoFaFields();
    const needsOtp = requiresOtp(fields2Fa);
    const chosen = needsOtp
      ? channelsFor(fields2Fa)[0]
      : null;
    const body = { ...attested };

    let response = null;

    try {
      response = await client.processes.authStep0(processId, body);
    } catch (error) {
      throw toCooldownError(error) || toVoteError(error, ErrorCode.AUTH_REJECTED);
    }

    if (!response || !response.authToken) {
      throw new VoteError(ErrorCode.AUTH_REJECTED);
    }

    authToken = response.authToken;
    // An auth-only census gets a token that is verified on arrival; a 2FA
    // census gets one that is not, and `authStep1` is the only thing that can
    // change that.
    verified = !needsOtp;
    channel = chosen;
    attestedContact = needsOtp && attested.contact && attested.salt
      ? { contact: attested.contact, salt: attested.salt }
      : null;

    return { needsOtp, channel: chosen };
  };

  /**
   * Step 2b — confirm the 2FA challenge. Only reached when the census declares
   * `twoFaFields`; auth-only censuses must never call this.
   *
   * A wrong code comes back as HTTP 401 code 40001, "challenge code do not
   * match", and leaves the token usable: it is classified `OTP_REJECTED` so the
   * voter can simply type it again. Anything else means the session itself is
   * gone and is classified `OTP_EXPIRED`, which sends them back to the start.
   *
   * @param {string} code - the one-time code the voter received.
   * @returns {Promise<void>} nothing; the stored token is verified in place.
   */
  const confirmOtp = async (code) => {
    const token = requirePendingToken();
    let response = null;

    try {
      response = await client.processes.authStep1(processId, { authToken: token, authData: [code] });
    } catch (error) {
      throw toCooldownError(error) ||
        toVoteError(error, apiErrorCode(error) === ApiErrorCode.AUTH_REQUIRED
          ? ErrorCode.OTP_REJECTED
          : ErrorCode.OTP_EXPIRED);
    }

    // The CSP verifies the token in place and echoes it back; it does not
    // always mint a new one. A 2xx is the success signal, so only adopt a
    // replacement when there is one rather than treating its absence as a
    // rejection.
    if (response && response.authToken) {
      authToken = response.authToken;
    }

    verified = true;
  };

  /**
   * Sends another one-time code down the same channel.
   *
   * `resend` needs the attested contact and salt spelled out, so they are
   * replayed from what {@link authenticate} kept. The token is unchanged, which
   * means an in-flight older code stays typable if the voter finds it first.
   *
   * @returns {Promise<{channel: string}>} the channel the code went to.
   */
  const resendOtp = async () => {
    const token = requirePendingToken();

    if (verified) {
      // Nothing to resend: this token is already through 2FA.
      throw new VoteError(ErrorCode.OTP_RESEND_FAILED);
    }

    const body = attestedContact;

    if (!body) {
      throw new VoteError(ErrorCode.OTP_RESEND_FAILED);
    }

    let response = null;

    try {
      response = await client.processes.resend(processId, { authToken: token, ...body });
    } catch (error) {
      throw toCooldownError(error) || toVoteError(error, ErrorCode.OTP_RESEND_FAILED);
    }

    if (response && response.authToken) {
      authToken = response.authToken;
    }

    return { channel };
  };

  return {
    reset,
    authenticate,
    confirmOtp,
    resendOtp,
    requireVerifiedToken,

    /**
     * A token exists — it may still be waiting for a one-time code.
     *
     * @returns {boolean} true once `authStep0` has succeeded.
     */
    get authenticated() {
      return Boolean(authToken);
    },

    /**
     * Every step the census demands is done. The only safe gate to vote on.
     *
     * @returns {boolean} true once the census is fully satisfied.
     */
    get verified() {
      return Boolean(authToken) && verified;
    }
  };
};

export default createAuthSession;
