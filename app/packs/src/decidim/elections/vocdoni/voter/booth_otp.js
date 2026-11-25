import { ErrorCode } from "src/decidim/elections/vocdoni/voter/errors";
import { interpolate, message } from "src/decidim/elections/vocdoni/voter/booth_text";

/**
 * Shows the OTP panel (the backend's pre-ballot partial) and resolves once the
 * CSP accepts a code. The panel's listeners are removed on success, so a later
 * sign-in on the same page does not confirm the code twice. Progress goes to
 * the booth's status line; errors go under the field, the way Decidim's form
 * builder shows them.
 *
 * @param {Object} ctx - booth context (config, showPanel, progress).
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
  const label = input.closest("label");
  const listeners = new AbortController();
  let cooldownTimer = null;

  const showError = (text) => {
    feedback.textContent = text || "";
    feedback.classList.toggle("is-visible", Boolean(text));
    input.classList.toggle("is-invalid-input", Boolean(text));
    if (label) {
      label.classList.toggle("is-invalid-label", Boolean(text));
    }
  };

  // Starts a server-driven countdown. Called only when the CSP says how long
  // to wait: either from a 40103 response's `coolDownTime` (via error.details.seconds)
  // or from a successful resend response's `coolDownTime` (ms, forwarded as coolDownMs).
  const cooldown = (seconds) => {
    let left = seconds;
    clearInterval(cooldownTimer);
    resend.disabled = true;
    // Show the initial count immediately so the voter sees it straight away.
    resend.textContent = interpolate(i18n.otp.resend_wait, { seconds: left });
    cooldownTimer = setInterval(() => {
      left -= 1;
      if (left <= 0) {
        clearInterval(cooldownTimer);
        resend.disabled = false;
        resend.textContent = i18n.otp.resend;
      } else {
        resend.textContent = interpolate(i18n.otp.resend_wait, { seconds: left });
      }
    }, 1000);
  };

  // No local cooldown on open: the CSP returns coolDownTime (ms) on a successful
  // step-0 / resend; the button is enabled until the server tells us to wait.
  input.value = "";
  input.focus();

  resend.addEventListener("click", async () => {
    showError("");
    ctx.progress(i18n.status.sending_code);
    try {
      const { coolDownMs } = await flow.resendOtp();

      ctx.progress(i18n.otp.resent);
      if (typeof coolDownMs === "number" && coolDownMs > 0) {
        cooldown(Math.ceil(coolDownMs / 1000));
      }
      // No server cooldown: button stays enabled, voter can resend again.
    } catch (error) {
      ctx.progress("");
      if (error.code === ErrorCode.AUTH_COOLDOWN) {
        cooldown(Math.max(1, Number(error.details?.seconds) || 0));
      }
      showError(message(i18n, error));
    }
  }, { signal: listeners.signal });

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const code = input.value.trim();
    if (!code) {
      showError(i18n.otp.required);
      return;
    }
    showError("");
    ctx.progress(i18n.status.authenticating);
    try {
      await flow.confirmOtp(code);
      clearInterval(cooldownTimer);
      listeners.abort();
      ctx.progress("");
      resolve();
    } catch (error) {
      ctx.progress("");
      showError(message(i18n, error));
      if (error.code === ErrorCode.OTP_EXPIRED) {
        resend.disabled = false;
      }
    }
  }, { signal: listeners.signal });
});
