import { interpolate, setDisabled, setText, toggle } from "src/decidim/elections/vocdoni/voter/dom";

/**
 * The "send me a new code" cooldown.
 *
 * Three things have to say the same thing at every instant, or the screen lies
 * to the voter at the most anxious moment of the flow:
 *
 *   the button   genuinely `disabled` — and therefore `aria-disabled` too,
 *                because {@link setDisabled} sets both — while the wait runs.
 *                It *looks* unavailable, so it has to *be* unavailable: a
 *                greyed-out control that still works teaches the voter that
 *                greyed-out means nothing, and lets a code be requested as fast
 *                as the button can be clicked.
 *   the line     "You can ask for a new code in N seconds", counted down once a
 *                second — and removed entirely when the wait is over, rather
 *                than replaced by a second sentence about a button that is now
 *                simply available.
 *   the moment   the wait ends is announced, once, in the live region. That is
 *                what replaces the click-refusal this used to rely on: a
 *                disabled button leaves the tab order, so nobody is left
 *                clicking at a control that answers nothing — but nobody is
 *                watching a silent countdown either.
 *
 * Keeping all three in one place is the point: they drifted apart when the
 * countdown and the click handler each owned half of the state.
 */

/** How long the voting page refuses to ask for another code. */
export const RESEND_COOLDOWN_MS = 30000;

/**
 * Wires a cooldown to a button and the line that describes it.
 *
 * @param {Object} options - dependencies.
 * @param {Element} options.button - the resend button.
 * @param {Element} options.hint - the countdown line beside it.
 * @param {Object} options.i18n - the loaded translations.
 * @param {Object} options.ui - the voting page's shared surfaces, for `announce`.
 * @returns {Object} `{ start, release, lock, locked }`.
 */
export const createResendCooldown = ({ button, hint, i18n, ui }) => {
  let timer = null;
  let until = 0;

  /**
   * Locks or unlocks the button, for real: `disabled` as well as
   * `aria-disabled`, so the DOM agrees with what the styling is saying.
   *
   * @param {boolean} isLocked - true while the button must not act.
   * @returns {void} nothing.
   */
  const lock = (isLocked) => setDisabled(button, isLocked);

  const stop = () => {
    if (timer) {
      window.clearInterval(timer);
      timer = null;
    }

    until = 0;
  };

  // How many whole seconds are left; 0 once the wait is over.
  const remainingSeconds = () => Math.max(0, Math.ceil((until - Date.now()) / 1000));

  const showCountdown = (seconds) => {
    lock(true);
    setText(hint, interpolate(i18n.otp.resend_wait, { seconds }));
    toggle(hint, true);
  };

  /**
   * Frees the button and takes the countdown line away with it.
   *
   * @returns {void} nothing.
   */
  const release = () => {
    stop();
    lock(false);
    setText(hint, "");
    toggle(hint, false);
  };

  // Not a live region: announcing every second would talk over the rest of the
  // step. Only the moment the wait ends is announced.
  const tick = () => {
    const remaining = remainingSeconds();

    if (remaining > 0) {
      showCountdown(remaining);

      return;
    }

    release();
    ui.announce(i18n.otp.resend_ready);
  };

  /**
   * Starts a wait. Called after every code the CSP sends, including the one
   * `authStep0` sends on the way into the step, so the button cannot be hammered
   * from the moment the screen appears.
   *
   * @param {number} [ms] - how long to wait.
   * @returns {void} nothing.
   */
  const start = (ms = RESEND_COOLDOWN_MS) => {
    stop();
    until = Date.now() + ms;
    showCountdown(Math.ceil(ms / 1000));
    timer = window.setInterval(tick, 1000);
  };

  /**
   * Whether the wait is still running.
   *
   * The button is genuinely `disabled` while it is, so no click from the page
   * can get past it; this is the belt to that pair of braces, for anything that
   * reaches the handler another way.
   *
   * @returns {boolean} true while a code must not be asked for.
   */
  const locked = () => remainingSeconds() > 0;

  return { start, release, lock, locked };
};

export default createResendCooldown;
