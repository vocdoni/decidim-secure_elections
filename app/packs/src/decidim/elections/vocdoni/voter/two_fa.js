/**
 * The census two-factor contract, in one place.
 *
 * `census.twoFaFields` (ARCHITECTURE §4c) is the *only* thing the voting page may branch
 * on to decide whether a one-time code is required:
 *
 *   []                 auth-only  - `authStep0` returns an already-verified token
 *   ["email"]          code by email
 *   ["phone"]          code by SMS
 *   ["email","phone"]  the voter picks the channel
 *
 * Why this is not derived from anything else: `processes.check` answers
 * `belongsToProcess: true` for a token that has *not* been through `authStep1`
 * yet (verified against staging). A successful check therefore proves nothing
 * about verification, and using it to open the ballot would let a voter past
 * 2FA by simply never entering the code.
 *
 * The channel is not only a delivery preference: `authStep0` on a 2FA census
 * rejects a body with no contact value (HTTP 400, code 40005 — "no contact
 * information provided"). The chosen channel's value is therefore collected on
 * the identification form, sent with `authStep0`, and kept to feed `resend`,
 * which likewise refuses a body without it.
 */

/** The contact fields the CSP can deliver a one-time code to. */
export const CHANNELS = ["email", "phone"];

/**
 * The delivery channels this census actually offers, in a stable order and
 * without anything the voting page cannot render.
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

/**
 * Whether the voter has a say in where the code goes. Only the
 * `["email","phone"]` census does; a single-channel census must not ask.
 *
 * @param {string[]} twoFaFields - `census.twoFaFields` from the process read.
 * @returns {boolean} true when the voter picks the channel.
 */
export const offersChannelChoice = (twoFaFields) => channelsFor(twoFaFields).length > 1;

/**
 * The channel to use when the voter is not asked, i.e. the only one on offer.
 *
 * @param {string[]} twoFaFields - `census.twoFaFields` from the process read.
 * @returns {string|null} the channel, or null for an auth-only census.
 */
export const defaultChannel = (twoFaFields) => {
  const channels = channelsFor(twoFaFields);

  return channels.length === 1
    ? channels[0]
    : null;
};

/**
 * The `resend` / `authStep0` body fragment carrying the contact value.
 * `resend` fails with "invalid user email" when it is missing, so the voting page
 * always sends it explicitly rather than relying on the CSP remembering.
 *
 * @param {string} channel - `email` or `phone`.
 * @param {string} value - the contact the voter supplied.
 * @returns {Object} `{ email }` or `{ phone }`, or `{}` when unusable.
 */
export const contactBody = (channel, value) => {
  if (!CHANNELS.includes(channel) || typeof value !== "string" || value.trim() === "") {
    return {};
  }

  return { [channel]: value.trim() };
};
