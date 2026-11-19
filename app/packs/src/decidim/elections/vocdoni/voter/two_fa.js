/**
 * The census two-factor contract, in one place.
 *
 * `census.twoFaFields` (ARCHITECTURE §4c) is the *only* thing the booth may branch
 * on to decide whether a one-time code is required:
 *
 *   []         auth-only - `authStep0` returns an already-verified token
 *   ["email"]  code by email
 *   ["phone"]  code by SMS
 *
 * Why this is not derived from anything else: `processes.check` answers
 * `belongsToProcess: true` for a token that has *not* been through `authStep1`
 * yet (verified against staging). A successful check therefore proves nothing
 * about verification, and using it to open the ballot would let a voter past
 * 2FA by simply never entering the code.
 */

/** The contact fields the CSP can deliver a one-time code to. */
export const CHANNELS = ["email", "phone"];

/**
 * The delivery channels this census actually offers, in a stable order.
 *
 * @param {string[]} twoFaFields - `census.twoFaFields` from the process read.
 * @returns {string[]} the supported channels, `[]` for an auth-only census.
 */
export const channelsFor = (twoFaFields) => {
  if (!Array.isArray(twoFaFields)) {
    return [];
  }

  return CHANNELS.filter((channel) => twoFaFields.includes(channel));
};

/**
 * Whether this census needs `authStep1` at all.
 *
 * @param {string[]} twoFaFields - `census.twoFaFields` from the process read.
 * @returns {boolean} true when a one-time code must be confirmed.
 */
export const requiresOtp = (twoFaFields) => channelsFor(twoFaFields).length > 0;
