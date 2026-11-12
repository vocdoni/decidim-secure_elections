import { ErrorCode } from "src/decidim/elections/vocdoni/voter/errors";
import { interpolate, message } from "src/decidim/elections/vocdoni/voter/booth_text";

const RESEND_COOLDOWN_S = 30;

/**
 * Shows the OTP panel (the backend's pre-ballot partial) and resolves once the
 * CSP accepts a code. The panel's listeners are removed on success, so a later
 * sign-in on the same page does not confirm the code twice.
 *
 * @param {Object} ctx - booth context (config, showPanel).
 * @param {Object} flow - the voter flow (`confirmOtp`, `resendOtp`).
 * @returns {Promise<void>} resolves once the code is accepted.
 */
export const runOtp = (ctx, flow) => new Promise((resolve) => {
  const { i18n } = ctx.config;
  const panel = ctx.showPanel();
  const form = panel.querySelector("[data-vocdoni-otp-form]");
  const input = panel.querySelector("[data-vocdoni-otp-code]");
  const feedback = panel.querySelector("[data-vocdoni-otp-feedback]");
  const resend = panel.querySelector("[data-vocdoni-otp-resend]");
  const listeners = new AbortController();
  let cooldownTimer = null;

  const cooldown = (seconds) => {
    resend.disabled = true;
    let left = seconds;
    clearInterval(cooldownTimer);
    cooldownTimer = setInterval(() => {
      left -= 1;
      resend.textContent = left > 0
        ? interpolate(i18n.otp.resend_wait, { seconds: left })
        : i18n.otp.resend;
      if (left <= 0) {
        clearInterval(cooldownTimer);
        resend.disabled = false;
      }
    }, 1000);
  };

  cooldown(RESEND_COOLDOWN_S);
  input.value = "";
  input.focus();

  resend.addEventListener("click", async () => {
    feedback.textContent = i18n.status.sending_code;
    try {
      await flow.resendOtp();
      feedback.textContent = i18n.otp.resent;
      cooldown(RESEND_COOLDOWN_S);
    } catch (error) {
      feedback.textContent = message(i18n, error);
    }
  }, { signal: listeners.signal });

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const code = input.value.trim();
    if (!code) {
      feedback.textContent = i18n.otp.required;
      return;
    }
    feedback.textContent = i18n.status.authenticating;
    try {
      await flow.confirmOtp(code);
      clearInterval(cooldownTimer);
      listeners.abort();
      feedback.textContent = "";
      resolve();
    } catch (error) {
      feedback.textContent = message(i18n, error);
      if (error.code === ErrorCode.OTP_EXPIRED) {
        resend.disabled = false;
      }
    }
  }, { signal: listeners.signal });
});
