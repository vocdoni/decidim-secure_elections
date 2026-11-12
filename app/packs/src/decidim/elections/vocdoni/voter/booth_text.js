/**
 * Text helpers shared by the client-side booth adapter and its panels.
 */

/**
 * Fills `%{key}` placeholders from `values`; unknown keys become "".
 *
 * @param {string} text - a Rails-style i18n string.
 * @param {Object} [values] - placeholder values.
 * @returns {string} the interpolated text.
 */
export const interpolate = (text, values = {}) => String(text || "").replace(/%\{(\w+)\}/g, (match, key) => (key in values
  ? values[key]
  : ""));

/**
 * The voter-facing message for a flow error, from `i18n.errors[code]`.
 *
 * @param {Object} i18n - the booth adapter's i18n.
 * @param {Object} error - a `VoteError` (or anything with a `message`).
 * @returns {string} the message.
 */
export const message = (i18n, error) => {
  const errors = (i18n && i18n.errors) || {};
  const code = error && error.code;

  if (code && errors[code]) {
    return interpolate(errors[code], error.details || {});
  }

  return errors.unknown || String(error && error.message);
};
