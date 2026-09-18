import { append, el, focusElement, qsa, setDisabled, setText, toggle } from "src/decidim/elections/vocdoni/voter/dom";
import { ErrorCode, toVoteError } from "src/decidim/elections/vocdoni/voter/errors";
import { CHANNELS } from "src/decidim/elections/vocdoni/voter/two_fa";
import { createResendCooldown } from "src/decidim/elections/vocdoni/voter/resend_cooldown";

/**
 * The one-time-code screen: ARCHITECTURE §3 step 2b.
 *
 * Honest states, all of them verified against staging:
 *
 *   wrong code       401/40001 "challenge code do not match" — the token
 *                    survives, so the voter retypes in place. No new code is
 *                    sent, no credential is re-entered, nothing is burnt.
 *   spent session    anything else from `authStep1` — the token is gone, so the
 *                    voter goes back to identification rather than looping.
 *   rate limited     401/40103 with `data.coolDownTime` — the CSP's own wait,
 *                    which is honoured over ours.
 *   delivery failure `resend` refused — say so and let them try again.
 *
 * The code input is a single ordinary text field with a real `<label>`. A
 * split-digit widget looks neater and breaks paste, `autocomplete="one-time-code"`
 * and screen readers, which is a bad trade for a control the voter must get
 * right on the first try.
 *
 * The resend affordance — the button, the countdown line and the moment the wait
 * ends — lives in `resend_cooldown.js`, which is where the three of them are
 * kept telling the same story.
 */

/**
 * Wires the one-time-code step.
 *
 * @param {Object} ctx - the voting page context (flow, i18n and ui).
 * @param {Object} handlers - what to do when the step ends.
 * @param {Function} handlers.onVerified - the code was accepted.
 * @param {Function} handlers.onRestart - the session is over; identify again.
 * @returns {Object} `{ bind, open, close }`.
 */
export const createOtpStep = (ctx, { onVerified, onRestart }) => {
  const { flow, i18n, ui } = ctx;

  const input = el("input", {
    type: "text",
    id: "js-vocdoni-otp-code",
    name: "vocdoni_otp_code",
    inputmode: "numeric",
    autocomplete: "one-time-code",
    spellcheck: "false",
    autocapitalize: "off",
    "aria-describedby": "js-vocdoni-otp-hint js-vocdoni-otp-error"
  });
  const errorNode = el("p", { id: "js-vocdoni-otp-error", class: "vocdoni-error", role: "alert", hidden: true });
  const submitButton = el("button", {
    type: "submit",
    id: "js-vocdoni-otp-submit",
    class: "vocdoni-button vocdoni-button--primary",
    text: i18n.otp.submit
  });
  const form = el("form", { id: "js-vocdoni-otp-form", novalidate: true, autocomplete: "off", class: "vocdoni-form" }, [
    el("div", { class: "vocdoni-field" }, [
      el("label", { class: "vocdoni-field__label", for: "js-vocdoni-otp-code", text: i18n.otp.label }),
      input,
      el("p", { id: "js-vocdoni-otp-hint", class: "vocdoni-hint", text: i18n.otp.hint })
    ]),
    errorNode,
    el("div", { class: "vocdoni-nav" }, [ui.exitLink(i18n.cancel), submitButton])
  ]);

  const resendButton = el("button", {
    type: "button",
    id: "js-vocdoni-otp-resend",
    class: "vocdoni-button vocdoni-button--quiet vocdoni-button--small",
    "aria-describedby": "js-vocdoni-otp-resend-hint",
    // Locked from the outset: `open` starts a cooldown for the code
    // `authStep0` has just sent, and the button must not be live for the tick
    // between being built and that cooldown starting.
    disabled: true,
    "aria-disabled": "true",
    text: i18n.otp.resend
  });
  const resendHint = el("p", { id: "js-vocdoni-otp-resend-hint", class: "vocdoni-hint", hidden: true });
  const restartButton = el("button", {
    type: "button",
    id: "js-vocdoni-otp-restart",
    class: "vocdoni-button vocdoni-button--quiet vocdoni-button--small",
    text: i18n.otp.restart
  });

  append(ui.stepNodes.otp, [
    ui.heading(i18n.otp.title),
    // One paragraph per channel, so the voter is told which inbox to look in.
    // The voting page shows the one matching the channel the code actually went to.
    CHANNELS.map((channel) => el("p", {
      dataset: { otpChannel: channel },
      hidden: true,
      text: i18n.otp[`body_${channel}`]
    })),
    form,
    el("div", { class: "vocdoni-resend" }, [
      resendButton,
      resendHint,
      el("p", { class: "vocdoni-hint" }, [i18n.otp.restart_body, " ", restartButton])
    ])
  ]);

  const cooldown = createResendCooldown({ button: resendButton, hint: resendHint, i18n, ui });
  // True while a resend is in flight; see `handleResend`.
  let resending = false;

  /**
   * Leaves the step, clearing the typed code and any pending timer.
   *
   * @returns {void} nothing.
   */
  const close = () => {
    cooldown.release();
    input.value = "";
    ui.showInlineError(errorNode, null);
  };

  /**
   * Opens the step for one channel, naming it in the copy so the voter knows
   * which inbox to look in.
   *
   * @param {string} channel - `email` or `phone`.
   * @returns {void} nothing.
   */
  const open = (channel) => {
    qsa("[data-otp-channel]", ui.stepNodes.otp).forEach((node) => {
      toggle(node, node.dataset.otpChannel === channel);
    });

    close();
    // A code has just been sent by `authStep0`; the cooldown starts with it.
    cooldown.start();
    // "Checking your details…" described the step we are leaving, not this one.
    ui.clearStatus();
    ui.showStep("otp");
  };

  const handleSubmit = async (event) => {
    event.preventDefault();
    ui.showInlineError(errorNode, null);

    const code = input.value.trim();

    if (code === "") {
      ui.showInlineError(errorNode, i18n.otp.required);
      ui.announce(i18n.otp.required);
      focusElement(input);

      return;
    }

    setDisabled(submitButton, true);
    setText(submitButton, i18n.status.authenticating);
    ui.announce(i18n.status.authenticating);

    try {
      await flow.confirmOtp(code);
      close();
      await onVerified();
    } catch (error) {
      const voteError = toVoteError(error, ErrorCode.OTP_REJECTED);

      // A spent session cannot be retried here: identifying again is the only
      // way to get a new code, so say so instead of looping on a dead token.
      if (voteError.code === ErrorCode.OTP_EXPIRED) {
        close();
        onRestart(voteError);

        return;
      }

      const message = ui.messageForError(voteError);

      ui.showInlineError(errorNode, message);
      ui.announce(message);
      // The token survives a wrong code, so keep the voter here with the field
      // selected and ready to be typed over.
      focusElement(input);

      if (typeof input.select === "function") {
        input.select();
      }
    } finally {
      setDisabled(submitButton, false);
      setText(submitButton, i18n.otp.submit);
    }
  };

  const handleResend = async () => {
    // The button is `disabled` for the whole cooldown, so a click cannot get
    // this far from the page; `cooldown.locked()` only guards against a caller
    // that reaches the handler another way. `resending` covers the gap the
    // cooldown cannot: between the click and the CSP's answer there is no wait
    // to count down, and a second click would send a second code.
    if (resending || cooldown.locked()) {
      return;
    }

    resending = true;
    ui.showInlineError(errorNode, null);
    cooldown.lock(true);
    ui.announce(i18n.status.sending_code);

    try {
      await flow.resendOtp();
      cooldown.start();
      ui.announce(i18n.otp.resent);
      focusElement(input);
    } catch (error) {
      const voteError = toVoteError(error, ErrorCode.OTP_RESEND_FAILED);

      // The CSP tells us how long it wants us to wait; honour its number rather
      // than our own, then let the voter try again.
      if (voteError.code === ErrorCode.AUTH_COOLDOWN) {
        cooldown.start(Math.max(1, Number(voteError.details.seconds) || 0) * 1000);
      } else {
        cooldown.release();
      }

      const message = ui.messageForError(voteError);

      ui.showInlineError(errorNode, message);
      ui.announce(message);
    } finally {
      resending = false;
    }
  };

  /**
   * Attaches the step's handlers.
   *
   * @returns {void} nothing.
   */
  const bind = () => {
    form.addEventListener("submit", handleSubmit);
    resendButton.addEventListener("click", handleResend);
    restartButton.addEventListener("click", () => {
      close();
      onRestart(null);
    });
  };

  return { bind, open, close };
};

export default createOtpStep;
