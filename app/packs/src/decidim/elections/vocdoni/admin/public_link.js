/**
 * Copy-to-clipboard for the public voting URL.
 *
 * The link is the one thing an organiser has to get out of Decidim and into an
 * email, so selecting it by hand out of a read-only input is the step worth
 * removing. Falls back to selecting the text when the Clipboard API is
 * unavailable (it needs a secure context, and plenty of Decidim installs are
 * reached over plain HTTP on a LAN).
 */
const FEEDBACK_SELECTOR = "[data-vocdoni-copy-feedback]";

const setupCopyButtons = () => {
  document.querySelectorAll("[data-vocdoni-copy-url]").forEach((button) => {
    const targetId = button.dataset.vocdoniCopyUrl;
    const input = document.getElementById(targetId);

    if (!input) {
      return;
    }

    const feedback = button.closest(".card-section")?.querySelector(FEEDBACK_SELECTOR);
    const announce = (message) => {
      if (feedback) {
        feedback.textContent = message;
      }
    };

    button.addEventListener("click", async () => {
      input.focus();
      input.select();

      try {
        if (navigator.clipboard && window.isSecureContext) {
          await navigator.clipboard.writeText(input.value);
          announce(button.dataset.vocdoniCopiedLabel || "Link copied.");
          return;
        }
      } catch {
        // Fall through to the selection fallback below.
      }

      // The text is selected either way, so the worst case is a manual Ctrl+C.
      announce(button.dataset.vocdoniCopyManualLabel || "Press Ctrl+C to copy the selected link.");
    });
  });
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", setupCopyButtons);
} else {
  setupCopyButtons();
}

export default setupCopyButtons;
