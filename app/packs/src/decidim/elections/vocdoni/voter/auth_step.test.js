/* global jest */

import { VoteError, ErrorCode } from "src/decidim/elections/vocdoni/voter/errors";
import { build, byId, fill, i18n, submit, visible } from "src/decidim/elections/vocdoni/voter/voting_page_fixture";

afterEach(() => {
  jest.useRealTimers();
  document.body.innerHTML = "";
});

describe("the identification form", () => {
  it("asks for no contact at all on an auth-only census", () => {
    build({ twoFaFields: [] });

    expect(visible(byId("js-vocdoni-auth-twofa"))).toBe(false);
    expect(visible(byId("js-vocdoni-auth-channel"))).toBe(false);
    expect(visible(document.querySelector("[data-twofa-field-wrapper='email']"))).toBe(false);
  });

  it("asks only for the declared channel when the census names one", () => {
    build({ twoFaFields: ["email"] });

    expect(visible(byId("js-vocdoni-auth-twofa"))).toBe(true);
    // Nothing to choose, so nothing is asked.
    expect(visible(byId("js-vocdoni-auth-channel"))).toBe(false);
    expect(visible(document.querySelector("[data-twofa-field-wrapper='email']"))).toBe(true);
    expect(visible(document.querySelector("[data-twofa-field-wrapper='phone']"))).toBe(false);
  });

  it("asks for the phone when the census names phone", () => {
    build({ twoFaFields: ["phone"] });

    expect(visible(byId("js-vocdoni-auth-channel"))).toBe(false);
    expect(visible(document.querySelector("[data-twofa-field-wrapper='phone']"))).toBe(true);
    expect(visible(document.querySelector("[data-twofa-field-wrapper='email']"))).toBe(false);
  });

  it("lets the voter choose when the census offers both, showing one field at a time", () => {
    build({ twoFaFields: ["email", "phone"] });

    expect(visible(byId("js-vocdoni-auth-channel"))).toBe(true);
    expect(visible(document.querySelector("[data-twofa-field-wrapper='email']"))).toBe(true);
    expect(visible(document.querySelector("[data-twofa-field-wrapper='phone']"))).toBe(false);

    const phone = document.querySelector("[data-twofa-channel='phone']");

    phone.checked = true;
    phone.dispatchEvent(new Event("change", { bubbles: true }));

    expect(visible(document.querySelector("[data-twofa-field-wrapper='phone']"))).toBe(true);
    expect(visible(document.querySelector("[data-twofa-field-wrapper='email']"))).toBe(false);
  });

  it("never requires a field it is hiding", () => {
    build({ twoFaFields: ["email", "phone"] });

    expect(document.querySelector("[data-twofa-field='email']").required).toBe(true);
    expect(document.querySelector("[data-twofa-field='phone']").required).toBe(false);
  });

  it("asks once when the census uses the same field as credential and contact", () => {
    build({ authFields: ["email"], twoFaFields: ["email"] });

    // The credential input is the contact; the dedicated one stays away.
    expect(visible(document.querySelector("[data-auth-field-wrapper='email']"))).toBe(true);
    expect(visible(document.querySelector("[data-twofa-field-wrapper='email']"))).toBe(false);
    expect(visible(byId("js-vocdoni-auth-twofa"))).toBe(false);
  });
});

describe("submitting the identification form", () => {
  it("sends credentials only on an auth-only census", async () => {
    const { flow } = build({ twoFaFields: [] });

    fill("[data-auth-field='memberNumber']", "1001");
    await submit("js-vocdoni-auth-form");

    expect(flow.authenticate).toHaveBeenCalledWith({ memberNumber: "1001" }, { channel: null, contact: "" });
    expect(flow.check).toHaveBeenCalled();
  });

  it("sends the contact with the credentials on a two-factor census", async () => {
    const { flow, ui } = build({ twoFaFields: ["email"] });

    fill("[data-auth-field='memberNumber']", "2001");
    fill("[data-twofa-field='email']", " carol@example.org ");
    await submit("js-vocdoni-auth-form");

    expect(flow.authenticate).toHaveBeenCalledWith(
      { memberNumber: "2001" },
      { channel: "email", contact: "carol@example.org" }
    );
    expect(ui.showStep).toHaveBeenCalledWith("otp");
    // The ballot is not opened by identification alone.
    expect(flow.check).not.toHaveBeenCalled();
  });

  it("sends the credential as the contact when they are the same field", async () => {
    const { flow } = build({ authFields: ["email"], twoFaFields: ["email"] });

    fill("[data-auth-field='email']", "carol@example.org");
    await submit("js-vocdoni-auth-form");

    expect(flow.authenticate).toHaveBeenCalledWith(
      { email: "carol@example.org" },
      { channel: "email", contact: "carol@example.org" }
    );
  });

  it("refuses to send with an empty contact rather than let the CSP 400", async () => {
    const { flow, ui } = build({ twoFaFields: ["email"] });

    fill("[data-auth-field='memberNumber']", "2001");
    await submit("js-vocdoni-auth-form");

    expect(flow.authenticate).not.toHaveBeenCalled();
    expect(ui.showInlineError).toHaveBeenCalledWith(byId("js-vocdoni-auth-error"), i18n.auth.required);
  });

  // "Checking what you can vote on…" is true for as long as the check is in
  // flight and a lie the moment the next screen is drawn.
  it("stops saying it is checking once the check has answered", async () => {
    const { ui } = build({ twoFaFields: [] });

    fill("[data-auth-field='memberNumber']", "1001");
    await submit("js-vocdoni-auth-form");

    expect(ui.announce).toHaveBeenCalledWith(i18n.status.checking);
    expect(ui.clearStatus).toHaveBeenCalled();
    expect(byId("js-vocdoni-vote-status").textContent).toBe("");
  });

  it("stops saying it is checking your details once the code screen is up", async () => {
    const { ui } = build({ twoFaFields: ["email"] });

    fill("[data-auth-field='memberNumber']", "2001");
    fill("[data-twofa-field='email']", "carol@example.org");
    await submit("js-vocdoni-auth-form");

    expect(ui.showStep).toHaveBeenCalledWith("otp");
    expect(byId("js-vocdoni-vote-status").textContent).toBe("");
  });

  it("reports a cooldown inline, so the voter keeps what they typed", async () => {
    const { flow, ui } = build({ twoFaFields: ["email"] });

    flow.authenticate.mockRejectedValue(new VoteError(ErrorCode.AUTH_COOLDOWN, { details: { seconds: 25 } }));
    fill("[data-auth-field='memberNumber']", "2001");
    fill("[data-twofa-field='email']", "carol@example.org");
    await submit("js-vocdoni-auth-form");

    expect(ui.showError).not.toHaveBeenCalled();
    expect(byId("js-vocdoni-auth-error").textContent).toBe("message:auth_cooldown");
  });
});
