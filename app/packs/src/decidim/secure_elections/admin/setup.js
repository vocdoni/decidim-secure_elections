/**
 * The point of no return, guarded in the browser as well as on the server.
 *
 * `SetupForm` already refuses a submission whose acknowledgement is unticked,
 * and that check stays: this file is a second lock, not the lock. What it adds
 * is that the button for an irreversible, unrecoverable action is not sitting
 * there enabled while the acknowledgement has not been given — an admin should
 * never be able to *press* it by accident and find out afterwards.
 *
 * With the pack unavailable the button stays enabled and the server refuses
 * the request, which is the behaviour this page has always had.
 */

const WRAPPER_ID = "js-vocdoni-setup";

const setupPublishGuard = () => {
  const wrapper = document.getElementById(WRAPPER_ID);

  if (!wrapper) {
    return;
  }

  const button = wrapper.querySelector("[data-vocdoni-publish]");
  const checkbox = wrapper.querySelector("[data-vocdoni-confirm-irreversible]");

  // The server already decided the election is not publishable — leave its
  // disabled button, and its explanation, exactly as rendered.
  if (!button || button.disabled || !checkbox) {
    return;
  }

  const hint = wrapper.querySelector("[data-vocdoni-publish-hint]");

  const refresh = () => {
    const ready = checkbox.checked;

    button.disabled = !ready;
    button.setAttribute("aria-disabled", String(!ready));

    if (hint) {
      hint.hidden = ready;
    }
  };

  checkbox.addEventListener("change", refresh);

  refresh();
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", setupPublishGuard);
} else {
  setupPublishGuard();
}

export default setupPublishGuard;
