/**
 * Error vocabulary for the voting page.
 *
 * The voting page never shows a raw API error to the voter: an error is classified
 * into one of a handful of *states*, each of which has an honest, actionable
 * message. In particular `RELAY_UNCONFIRMED` exists because a vote that fails
 * mid-relay may still have landed on chain — telling the voter it failed would
 * be a lie, and would push them into casting a second (rejected) ballot.
 *
 * NETWORK            the browser could not reach the API (offline, DNS, CORS)
 * AUTH_REJECTED      the census rejected the supplied credentials
 * AUTH_COOLDOWN      too many code requests too fast; the CSP says to wait
 * OTP_REJECTED       the 2FA code did not match — retryable, the token survives
 * OTP_EXPIRED        the 2FA session is over; the voter must identify again
 * OTP_RESEND_FAILED  the CSP would not send another code
 * SIGN_REJECTED      the CSP refused to sign, usually a consumed slot
 * KEYS_UNAVAILABLE   secret-until-the-end keys were never published
 * RELAY_UNCONFIRMED  we lost track of a relay: the vote MAY have landed
 * RELAY_REJECTED     the chain rejected the vote
 * BALLOT_UNSUPPORTED the ballot could not be encoded for this protocol
 * PROCESS_UNAVAILABLE the process could not be read
 * UNKNOWN            anything we did not anticipate
 */

export const ErrorCode = {
  NETWORK: "network",
  AUTH_REJECTED: "auth_rejected",
  AUTH_COOLDOWN: "auth_cooldown",
  OTP_REJECTED: "otp_rejected",
  OTP_EXPIRED: "otp_expired",
  OTP_RESEND_FAILED: "otp_resend_failed",
  SIGN_REJECTED: "sign_rejected",
  KEYS_UNAVAILABLE: "keys_unavailable",
  RELAY_UNCONFIRMED: "relay_unconfirmed",
  RELAY_REJECTED: "relay_rejected",
  BALLOT_UNSUPPORTED: "ballot_unsupported",
  PROCESS_UNAVAILABLE: "process_unavailable",
  UNKNOWN: "unknown"
};

/** An error the voting page knows how to present to a voter. */
export class VoteError extends Error {

  /**
   * Builds a classified voting page error.
   *
   * @param {string} code - one of {@link ErrorCode}.
   * @param {Object} [options] - extra context.
   * @param {Error} [options.cause] - the underlying error. It is kept for
   *   callers to inspect, and is never rendered or logged.
   * @param {Object} [options.details] - values the message interpolates, e.g.
   *   `{ seconds }` for a cooldown. Never anything secret.
   */
  constructor(code, options = {}) {
    super(code);
    this.name = "VoteError";
    this.code = code;
    this.cause = options.cause;
    this.details = options.details || {};
  }
}

/**
 * Backend error codes the voting page has to tell apart. They are the `code` field of
 * the API's error body, not the HTTP status: the CSP answers 401 for a wrong
 * one-time code, for a cooldown and for an unverified token alike, so the HTTP
 * status on its own cannot drive an honest message.
 *
 * Observed against the live API.
 */
export const ApiErrorCode = {
  // 401 - "challenge code do not match", also "the token is not verified".
  AUTH_REQUIRED: 40001,

  // 400 - "no contact information provided (email or phone)".
  MISSING_CONTACT: 40005,

  // 404 - "census participant not found"; also raised for a wrong contact.
  PARTICIPANT_NOT_FOUND: 40029,

  // 401 - "attempt cooldown time not reached", with `data.coolDownTime`.
  COOLDOWN: 40103
};

/**
 * The backend's own error code, when the throwable is an API error.
 *
 * @param {*} error - any throwable.
 * @returns {number|null} the numeric code, or null.
 */
export const apiErrorCode = (error) => {
  if (!error) {
    return null;
  }

  const code = typeof error.code === "number"
    ? error.code
    : error.body && error.body.code;

  return typeof code === "number"
    ? code
    : null;
};

/** Nothing sensible is longer than this; a bogus value must not lock the UI. */
const MAX_COOLDOWN_MS = 10 * 60 * 1000;

/**
 * How long the CSP wants us to wait, from a cooldown error.
 *
 * `data.coolDownTime` is in **milliseconds**: staging answered 24588 and the
 * very next attempt, 28 seconds later, was accepted.
 *
 * @param {*} error - the throwable from an auth call.
 * @returns {number|null} milliseconds to wait, or null when unknown.
 */
export const cooldownMsFrom = (error) => {
  const raw = error && error.body && error.body.data && error.body.data.coolDownTime;

  if (typeof raw !== "number" || !Number.isFinite(raw) || raw <= 0) {
    return null;
  }

  return Math.min(Math.round(raw), MAX_COOLDOWN_MS);
};

/**
 * True when the failure is "we could not talk to the server", as opposed to
 * "the server said no". `fetch` rejects with a TypeError for every transport
 * level failure; `AbortError` covers timeouts and page unloads.
 *
 * @param {*} error - any throwable.
 * @returns {boolean} true for transport failures.
 */
export const isNetworkError = (error) => {
  if (!error) {
    return false;
  }

  if (error instanceof VoteError) {
    return error.code === ErrorCode.NETWORK;
  }

  // An API error always carries an HTTP status; a transport failure never does.
  if (typeof error.status === "number") {
    return false;
  }

  return error.name === "TypeError" || error.name === "AbortError" || error.name === "TimeoutError";
};

/**
 * Wraps an arbitrary throwable into a {@link VoteError} with a sensible code.
 *
 * @param {*} error - the original throwable.
 * @param {string} fallback - the code to use when nothing more specific applies.
 * @returns {VoteError} the classified error.
 */
export const toVoteError = (error, fallback = ErrorCode.UNKNOWN) => {
  if (error instanceof VoteError) {
    return error;
  }

  return new VoteError(isNetworkError(error)
    ? ErrorCode.NETWORK
    : fallback, { cause: error });
};

/**
 * The cooldown a rate-limited auth call ran into, as a voting page error carrying the
 * seconds to show the voter.
 *
 * @param {*} error - the throwable from an auth call.
 * @returns {VoteError|null} the classified error, or null when it is not one.
 */
export const toCooldownError = (error) => {
  if (apiErrorCode(error) !== ApiErrorCode.COOLDOWN) {
    return null;
  }

  const waitMs = cooldownMsFrom(error);

  return new VoteError(ErrorCode.AUTH_COOLDOWN, {
    cause: error,
    details: { seconds: Math.max(1, Math.ceil((waitMs || 0) / 1000)) }
  });
};
