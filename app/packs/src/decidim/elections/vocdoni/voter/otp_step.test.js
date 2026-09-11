/* global jest */

import { VoteError, ErrorCode } from "src/decidim/elections/vocdoni/voter/errors";
import { byId, click, i18n, openOtp, submit, visible } from "src/decidim/elections/vocdoni/voter/voting_page_fixture";
import { interpolate } from "src/decidim/elections/vocdoni/voter/dom";

/**
 * The countdown copy, built from the strings the gem actually ships so the
 * assertions survive a rewording of `en.vote.yml`.
 *
 * @param {number} seconds - the wait the voting page should be showing.
 * @returns {string} the expected hint.
 */
const waitHint = (seconds) => interpolate(i18n.otp.resend_wait, { seconds });

afterEach(() => {
  jest.useRealTimers();
  document.body.innerHTML = "";
});

describe("the one-time-code screen", () => {
  it("names the channel the code actually went to", async () => {
    await openOtp({ twoFaFields: ["email"] });

    expect(visible(document.querySelector("[data-otp-channel='email']"))).toBe(true);
    expect(visible(document.querySelector("[data-otp-channel='phone']"))).toBe(false);
  });

  it("offers a plain, pasteable input rather than a split-digit widget", async () => {
    await openOtp();

    const input = byId("js-vocdoni-otp-code");

    expect(document.querySelectorAll("#js-vocdoni-otp-form input")).toHaveLength(1);
    expect(input.getAttribute("inputmode")).toBe("numeric");
    expect(input.getAttribute("autocomplete")).toBe("one-time-code");
  });

  it("confirms the code and only then opens the ballot", async () => {
    const { flow } = await openOtp();

    byId("js-vocdoni-otp-code").value = " 123456 ";
    await submit("js-vocdoni-otp-form");

    expect(flow.confirmOtp).toHaveBeenCalledWith("123456");
    expect(flow.check).toHaveBeenCalled();
  });

  it("will not send an empty code", async () => {
    const { flow } = await openOtp();

    await submit("js-vocdoni-otp-form");

    expect(flow.confirmOtp).not.toHaveBeenCalled();
    expect(byId("js-vocdoni-otp-error").textContent).toBe(i18n.otp.required);
  });

  it("keeps the voter on the step after a wrong code, ready to retype", async () => {
    const { flow, ui } = await openOtp();

    flow.confirmOtp.mockRejectedValue(new VoteError(ErrorCode.OTP_REJECTED));
    byId("js-vocdoni-otp-code").value = "000000";
    await submit("js-vocdoni-otp-form");

    expect(ui.showError).not.toHaveBeenCalled();
    expect(flow.reset).not.toHaveBeenCalled();
    expect(byId("js-vocdoni-otp-error").textContent).toBe("message:otp_rejected");
    expect(document.activeElement).toBe(byId("js-vocdoni-otp-code"));

    // The session survived, so a second attempt just works.
    flow.confirmOtp.mockResolvedValue();
    byId("js-vocdoni-otp-code").value = "123456";
    await submit("js-vocdoni-otp-form");
    expect(flow.check).toHaveBeenCalled();
  });

  it("sends the voter back to identification when the session is spent", async () => {
    const { flow, ui } = await openOtp();

    flow.confirmOtp.mockRejectedValue(new VoteError(ErrorCode.OTP_EXPIRED));
    byId("js-vocdoni-otp-code").value = "000000";
    await submit("js-vocdoni-otp-form");

    expect(flow.reset).toHaveBeenCalled();
    expect(ui.showStep).toHaveBeenLastCalledWith("auth");
    expect(byId("js-vocdoni-auth-error").textContent).toBe("message:otp_expired");
    expect(byId("js-vocdoni-otp-code").value).toBe("");
  });

  it("clears the session when the voter starts again", async () => {
    const { flow, ui } = await openOtp();

    await click("js-vocdoni-otp-restart");

    expect(flow.reset).toHaveBeenCalled();
    expect(ui.showStep).toHaveBeenLastCalledWith("auth");
  });
});

describe("resending the code", () => {
  it("is locked from the moment the step opens, because a code just went out", async () => {
    await openOtp({ fakeTimers: true });

    expect(byId("js-vocdoni-otp-resend").disabled).toBe(true);
    expect(byId("js-vocdoni-otp-resend").getAttribute("aria-disabled")).toBe("true");
    expect(byId("js-vocdoni-otp-resend-hint").textContent).toBe(waitHint(30));
  });

  it("counts down without announcing every second", async () => {
    const { ui } = await openOtp({ fakeTimers: true });

    ui.announce.mockClear();
    jest.advanceTimersByTime(10000);

    expect(byId("js-vocdoni-otp-resend-hint").textContent).toBe(waitHint(20));
    expect(ui.announce).not.toHaveBeenCalled();
  });

  it("unlocks and announces exactly once when the wait is over", async () => {
    const { ui } = await openOtp({ fakeTimers: true });

    ui.announce.mockClear();
    jest.advanceTimersByTime(31000);

    expect(byId("js-vocdoni-otp-resend").disabled).toBe(false);
    expect(byId("js-vocdoni-otp-resend").getAttribute("aria-disabled")).toBe("false");
    expect(ui.announce).toHaveBeenCalledTimes(1);
    expect(ui.announce).toHaveBeenCalledWith(i18n.otp.resend_ready);
  });

  // A countdown that outlives the wait it was counting is just another line of
  // text contradicting the button beside it.
  it("takes the countdown line away once there is nothing left to wait for", async () => {
    await openOtp({ fakeTimers: true });

    expect(visible(byId("js-vocdoni-otp-resend-hint"))).toBe(true);

    jest.advanceTimersByTime(31000);

    expect(visible(byId("js-vocdoni-otp-resend-hint"))).toBe(false);
    expect(byId("js-vocdoni-otp-resend-hint").textContent).toBe("");
  });

  it("cannot be hammered: a click during the cooldown does nothing", async () => {
    const { flow } = await openOtp({ fakeTimers: true });

    byId("js-vocdoni-otp-resend").click();
    await Promise.resolve();

    expect(flow.resendOtp).not.toHaveBeenCalled();
  });

  // The click above is refused by the DOM, but the handler is reachable from
  // elsewhere; it has to refuse an early call on its own account too.
  it("refuses a resend asked for mid-countdown however it is asked for", async () => {
    const { flow } = await openOtp({ fakeTimers: true });

    jest.advanceTimersByTime(5000);
    byId("js-vocdoni-otp-resend").dispatchEvent(new window.Event("click"));
    await Promise.resolve();

    expect(flow.resendOtp).not.toHaveBeenCalled();
    expect(byId("js-vocdoni-otp-resend-hint").textContent).toBe(waitHint(25));
  });

  it("asks for a new code once the cooldown is over, then locks again", async () => {
    const { flow, ui } = await openOtp({ fakeTimers: true });

    jest.advanceTimersByTime(31000);
    byId("js-vocdoni-otp-resend").click();
    await Promise.resolve();
    await Promise.resolve();

    expect(flow.resendOtp).toHaveBeenCalled();
    expect(ui.announce).toHaveBeenCalledWith(i18n.otp.resent);
    expect(byId("js-vocdoni-otp-resend").getAttribute("aria-disabled")).toBe("true");
  });

  // Between the click and the CSP's answer there is no countdown to refuse a
  // second click, so the handler has to.
  it("sends one code however fast the button is clicked twice", async () => {
    const { flow } = await openOtp({ fakeTimers: true });

    jest.advanceTimersByTime(31000);
    byId("js-vocdoni-otp-resend").click();
    byId("js-vocdoni-otp-resend").click();
    await Promise.resolve();
    await Promise.resolve();

    expect(flow.resendOtp).toHaveBeenCalledTimes(1);
  });

  it("honours the CSP's own cooldown over ours", async () => {
    const { flow } = await openOtp({ fakeTimers: true });

    jest.advanceTimersByTime(31000);
    flow.resendOtp.mockRejectedValue(new VoteError(ErrorCode.AUTH_COOLDOWN, { details: { seconds: 90 } }));
    byId("js-vocdoni-otp-resend").click();
    await Promise.resolve();
    await Promise.resolve();

    expect(byId("js-vocdoni-otp-resend").getAttribute("aria-disabled")).toBe("true");
    expect(byId("js-vocdoni-otp-resend-hint").textContent).toBe(waitHint(90));
    expect(byId("js-vocdoni-otp-error").textContent).toBe("message:auth_cooldown");
  });

  it("lets the voter try again after a delivery failure", async () => {
    const { flow } = await openOtp({ fakeTimers: true });

    jest.advanceTimersByTime(31000);
    flow.resendOtp.mockRejectedValue(new VoteError(ErrorCode.OTP_RESEND_FAILED));
    byId("js-vocdoni-otp-resend").click();
    await Promise.resolve();
    await Promise.resolve();

    expect(byId("js-vocdoni-otp-resend").getAttribute("aria-disabled")).toBe("false");
    expect(byId("js-vocdoni-otp-error").textContent).toBe("message:otp_resend_failed");
  });
});
