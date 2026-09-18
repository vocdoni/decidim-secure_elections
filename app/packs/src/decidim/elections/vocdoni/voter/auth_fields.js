import { el } from "src/decidim/elections/vocdoni/voter/dom";

/**
 * The credential inputs of the identification form.
 *
 * Kept apart from `auth_step.js` so that the markup and the behaviour can be
 * read — and reviewed — separately. Everything accessibility-relevant about a
 * census field is decided here: its `<label for>`, the input `type` that
 * summons the right keyboard, and the `autocomplete` token that lets a browser
 * or a password manager fill it in.
 *
 * Only the fields the live census declares are built at all. The old
 * server-rendered voting page painted every supported field and hid the rest, which
 * left a form full of controls that were in the DOM but meant nothing.
 */

/** Input types for the census fields that are not plain text. */
export const FIELD_TYPES = { birthDate: "date", email: "email", phone: "tel" };

/** Autofill hints, so the browser can offer what it already knows. */
export const FIELD_AUTOCOMPLETE = {
  email: "email",
  phone: "tel",
  name: "given-name",
  surname: "family-name",
  birthDate: "bday"
};

/**
 * Builds one labelled credential input.
 *
 * @param {string} field - the census field id, e.g. `memberNumber`.
 * @param {Object} i18n - the loaded translations.
 * @returns {Element} the field wrapper.
 */
export const buildCredentialField = (field, i18n) => el("div", {
  class: "vocdoni-field",
  dataset: { authFieldWrapper: field }
}, [
  el("label", {
    class: "vocdoni-field__label",
    for: `vocdoni-auth-${field}`,
    // A census may ask for a field this release has no label for; showing its
    // id is ugly but honest, and still leaves the input labelled.
    text: (i18n.fields && i18n.fields[field]) || field
  }),
  el("input", {
    type: FIELD_TYPES[field] || "text",
    id: `vocdoni-auth-${field}`,
    name: `vocdoni_auth_${field}`,
    dataset: { authField: field },
    autocomplete: FIELD_AUTOCOMPLETE[field] || "off",
    spellcheck: "false",
    // The form's single error message describes every input in it, so a
    // rejection is read out with whichever field the voter is standing on.
    "aria-describedby": "js-vocdoni-auth-error"
  })
]);

export default buildCredentialField;
