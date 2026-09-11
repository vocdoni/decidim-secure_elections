import { append, clear, el, qs, qsa, setText, toggle } from "src/decidim/elections/vocdoni/voter/dom";
import { CHANNELS, channelsFor, offersChannelChoice } from "src/decidim/elections/vocdoni/voter/two_fa";

/**
 * The two-factor part of the identification form: where the code should go, and
 * the address or number to send it to.
 *
 * It lives on the *identification* form rather than on the code screen because
 * `authStep0` refuses a body that carries only the credentials (HTTP 400, code
 * 40005 — "no contact information provided"). The code is sent by step 0, so the
 * only moment at which the voter can still influence where it goes is before
 * that call. ARCHITECTURE §4c-bis:
 *
 *   []                 nothing is asked
 *   ["email"]          one email field, no choice offered
 *   ["phone"]          one phone field, no choice offered
 *   ["email","phone"]  a radio picks the channel, and its field is shown
 *
 * The fields are built from the *live* census read, so an election edited after
 * the voting page link was handed out still produces the right form.
 *
 * The channel picker is a real nested `<fieldset>`/`<legend>` with native
 * radios rather than a `role="radiogroup"` div: the browser then gives us the
 * grouping, the label and the arrow-key behaviour for free, which is exactly the
 * kind of thing that gets lost when markup moves into JavaScript.
 *
 * The legend asks *where* the code should go — it must not promise a code field,
 * because the control underneath it is an address or a number. For the same
 * reason the help text names the thing being asked for ("Enter the email address
 * registered for you…") and follows the selected channel, and it is wired into
 * each contact input's `aria-describedby` so it is read with the field it
 * actually describes rather than floating above the section.
 */

/** `type` and `autocomplete` happen to coincide for both contact channels. */
const CONTACT_TYPES = { email: "email", phone: "tel" };

/** The help text, and then the form-wide error, describe every contact input. */
const CONTACT_DESCRIBED_BY = "js-vocdoni-auth-twofa-help js-vocdoni-auth-error";

/**
 * Wires the contact fieldset of the identification form.
 *
 * @param {Object} options - dependencies.
 * @param {Element} options.authForm - the identification form.
 * @param {Object} options.i18n - the loaded translations.
 * @returns {Object} the fieldset's API.
 */
export const createTwoFaForm = ({ authForm, i18n }) => {
  const choice = el("fieldset", { id: "js-vocdoni-auth-channel", class: "vocdoni-fieldset", hidden: true });
  const fields = el("div", { class: "vocdoni-field-list" });
  // Filled in by `renderFields`: which contact is being asked for depends on the
  // channel, and on a voter's-choice census that changes under the voter's hand.
  const help = el("p", { id: "js-vocdoni-auth-twofa-help", class: "vocdoni-hint" });
  const section = el("fieldset", { id: "js-vocdoni-auth-twofa", class: "vocdoni-fieldset", hidden: true }, [
    el("legend", { class: "vocdoni-field__label", text: i18n.auth.twofa_legend }),
    help,
    choice,
    fields
  ]);

  let channels = [];
  // Fields that are a credential *and* the contact, so the value is asked for
  // once. `email`/`phone` are not meant to be credentials (ARCHITECTURE §4c), but
  // the admin form does allow it.
  let shared = new Set();

  /**
   * How many channels this census offers.
   *
   * @returns {number} 0, 1 or 2.
   */
  const channelCount = () => channels.length;

  /**
   * The channel the voter selected, or the only one on offer.
   *
   * @returns {string|null} `email`, `phone` or null.
   */
  const selectedChannel = () => {
    if (channels.length === 0) {
      return null;
    }

    if (channels.length === 1) {
      return channels[0];
    }

    const checked = qsa("[data-twofa-channel]", choice).find((input) => input.checked);

    return checked
      ? checked.dataset.twofaChannel
      : null;
  };

  /**
   * The dedicated contact input for a channel, or null when the credential
   * input already collects it.
   *
   * @param {string} channel - `email` or `phone`.
   * @returns {Element|null} the input.
   */
  const contactInput = (channel) => (channel && !shared.has(channel)
    ? qs(`[data-twofa-field="${channel}"]`, section)
    : null);

  /**
   * The contact value for a channel: what the voter typed in the dedicated
   * field, or the credential itself when the census asks for the same field
   * twice.
   *
   * @param {string} channel - `email` or `phone`.
   * @returns {string} the contact, possibly empty.
   */
  const contactValue = (channel) => {
    if (!channel) {
      return "";
    }

    const dedicated = contactInput(channel);
    const input = dedicated || qs(`[data-auth-field="${channel}"]`, authForm);

    return input
      ? input.value.trim()
      : "";
  };

  /**
   * Shows only the contact field belonging to the selected channel, and the
   * help that names what that field wants.
   *
   * @returns {void} nothing.
   */
  const renderFields = () => {
    const active = selectedChannel();

    setText(help, (active && (i18n.auth.twofa_help || {})[active]) || "");

    CHANNELS.forEach((channel) => {
      const wrapper = qs(`[data-twofa-field-wrapper="${channel}"]`, fields);
      const visible = channels.includes(channel) && !shared.has(channel) &&
        (channels.length === 1 || channel === active);

      toggle(wrapper, visible);

      const input = wrapper && qs("[data-twofa-field]", wrapper);

      if (input) {
        // A hidden required field would block submission with no visible cause.
        input.required = visible;
      }
    });
  };

  /**
   * Builds the channel picker and one contact field per offered channel.
   *
   * @returns {void} nothing.
   */
  const build = () => {
    clear(choice);
    clear(fields);

    append(choice, [
      el("legend", { class: "vocdoni-field__label", text: i18n.auth.channel_legend }),
      channels.map((channel, index) => el("label", {
        class: "vocdoni-choice vocdoni-choice--inline",
        for: `vocdoni-twofa-channel-${channel}`
      }, [
        el("input", {
          type: "radio",
          id: `vocdoni-twofa-channel-${channel}`,
          name: "vocdoni_twofa_channel",
          value: channel,
          dataset: { twofaChannel: channel },
          checked: index === 0
        }),
        el("span", { text: i18n.auth.channel[channel] })
      ]))
    ]);

    append(fields, channels.
      filter((channel) => !shared.has(channel)).
      map((channel) => el("div", {
        class: "vocdoni-field",
        dataset: { twofaFieldWrapper: channel },
        hidden: true
      }, [
        el("label", { class: "vocdoni-field__label", for: `vocdoni-twofa-${channel}`, text: i18n.auth.contact[channel] }),
        el("input", {
          type: CONTACT_TYPES[channel] || "text",
          id: `vocdoni-twofa-${channel}`,
          name: `vocdoni_twofa_${channel}`,
          dataset: { twofaField: channel },
          autocomplete: CONTACT_TYPES[channel] || "off",
          spellcheck: "false",
          "aria-describedby": CONTACT_DESCRIBED_BY
        })
      ])));
  };

  /**
   * Applies the live census to the fieldset.
   *
   * @param {Set} declaredAuthFields - the credentials the census asks for.
   * @param {string[]} twoFaFields - the census `twoFaFields`.
   * @returns {void} nothing.
   */
  const applyCensus = (declaredAuthFields, twoFaFields) => {
    channels = channelsFor(twoFaFields);
    shared = new Set(channels.filter((channel) => declaredAuthFields.has(channel)));

    const needsContact = channels.some((channel) => !shared.has(channel));

    build();
    toggle(section, needsContact);
    toggle(choice, needsContact && offersChannelChoice(twoFaFields));
    renderFields();
  };

  /**
   * Keeps the visible field in step with the selected channel.
   *
   * Delegated from the section, because the radios are rebuilt every time the
   * census is applied and a listener bound to a replaced node is a listener
   * bound to nothing.
   *
   * @returns {void} nothing.
   */
  const bind = () => section.addEventListener("change", (event) => {
    if (event.target && event.target.dataset && event.target.dataset.twofaChannel) {
      renderFields();
    }
  });

  return { section, choice, bind, applyCensus, channelCount, selectedChannel, contactInput, contactValue };
};

export default createTwoFaForm;
