/* global jest */

import { build, byId, i18n } from "src/decidim/elections/vocdoni/voter/voting_page_fixture";

/**
 * The contact section of the identification form is the highest-anxiety moment
 * of the whole voting page: the voter has typed a credential and is being asked for
 * one more thing before anything happens. Every word here has to point at the
 * control underneath it.
 *
 * The failure this guards against is a section headed "One-time code" whose only
 * field is an email address, with a helper — "It must be the one registered for
 * you" — whose "it" grammatically attaches to the code rather than to the
 * address.
 */

afterEach(() => {
  jest.useRealTimers();
  document.body.innerHTML = "";
});

/**
 * Selects a delivery channel the way a voter would.
 *
 * @param {string} channel - `email` or `phone`.
 * @returns {void} nothing.
 */
const choose = (channel) => {
  const radio = document.querySelector(`[data-twofa-channel='${channel}']`);

  radio.checked = true;
  radio.dispatchEvent(new Event("change", { bubbles: true }));
};

describe("the contact section", () => {
  it("is titled after what it asks for, not after the code it will send", () => {
    build({ twoFaFields: ["email"] });

    expect(byId("js-vocdoni-auth-twofa").querySelector("legend").textContent).
      toBe(i18n.auth.twofa_legend);
    expect(i18n.auth.twofa_legend).not.toBe(i18n.otp.label);
  });

  it("names the contact the census wants, in the imperative", () => {
    build({ twoFaFields: ["email"] });

    expect(byId("js-vocdoni-auth-twofa-help").textContent).toBe(i18n.auth.twofa_help.email);
  });

  it("says mobile number rather than email address on an SMS census", () => {
    build({ twoFaFields: ["phone"] });

    expect(byId("js-vocdoni-auth-twofa-help").textContent).toBe(i18n.auth.twofa_help.phone);
  });

  // The help has to be read *with* the input, not float above the section.
  it("describes each contact input with the help and the form's error", () => {
    build({ twoFaFields: ["email", "phone"] });

    ["email", "phone"].forEach((channel) => {
      expect(document.querySelector(`[data-twofa-field='${channel}']`).getAttribute("aria-describedby")).
        toBe("js-vocdoni-auth-twofa-help js-vocdoni-auth-error");
    });
  });

  it("follows the voter's choice, so the help never describes the hidden field", () => {
    build({ twoFaFields: ["email", "phone"] });

    expect(byId("js-vocdoni-auth-twofa-help").textContent).toBe(i18n.auth.twofa_help.email);

    choose("phone");
    expect(byId("js-vocdoni-auth-twofa-help").textContent).toBe(i18n.auth.twofa_help.phone);

    choose("email");
    expect(byId("js-vocdoni-auth-twofa-help").textContent).toBe(i18n.auth.twofa_help.email);
  });

  it("keeps the channel picker's own legend distinct from the section's", () => {
    build({ twoFaFields: ["email", "phone"] });

    expect(byId("js-vocdoni-auth-channel").querySelector("legend").textContent).
      toBe(i18n.auth.channel_legend);
    expect(i18n.auth.channel_legend).not.toBe(i18n.auth.twofa_legend);
  });
});
