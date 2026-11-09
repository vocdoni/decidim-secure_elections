/**
 * Security tab: progressive enhancement, nothing load-bearing.
 *
 * The server renders every state from what is saved. This keeps the page in
 * step while the admin changes things without saving:
 *
 * 1. The whole vote-type card selects its option, and the selected card is
 *    highlighted (browsers without `:has()`). Without JavaScript the radio
 *    and the card title still do.
 * 2. The one-time code block is shown, and its fieldset usable, only while
 *    the secret vote is selected — unless the fieldset carries
 *    `data-security-locked`, in which case it stays disabled regardless
 *    of the vote type (feature not yet available).
 *
 * The section header is a native `<details>`, so it needs nothing here. The
 * resulting configuration is summarised on the Dashboard, from saved data.
 *
 * Selectors are ids with a `js-` prefix or `data-` attributes, never classes.
 */

const CHOICE_ID = "js-security-choice";
const TWO_FACTOR_ID = "js-security-two-factor";

const setupSecurity = () => {
  const choice = document.getElementById(CHOICE_ID);
  const twoFactor = document.getElementById(TWO_FACTOR_ID);

  if (!choice || !twoFactor) {
    return;
  }

  const radios = Array.from(choice.querySelectorAll("[data-security-choice]"));
  const cards = Array.from(choice.querySelectorAll("[data-security-choice-card]"));
  const locked = "securityLocked" in twoFactor.dataset;

  const selected = () => {
    const radio = radios.find((input) => input.checked);
    return radio
      ? radio.dataset.securityChoice
      : "";
  };

  const sync = () => {
    const value = selected();
    cards.forEach((card) => {
      card.classList.toggle("is-selected", card.dataset.securityChoiceCard === value);
    });

    // Show the fieldset when the secret vote is selected so the admin
    // sees the "not available yet" note; hide it again for the simple vote.
    // If the fieldset is locked, it stays disabled regardless of the choice
    // (locked means the feature is not available; a disabled fieldset submits
    // nothing so no stale code choice is ever sent).
    const secure = value === "secure";
    twoFactor.hidden = !secure;
    twoFactor.disabled = !secure || locked;
  };

  cards.forEach((card) => {
    card.addEventListener("click", (event) => {
      // Links, the radio and its label already do their own thing, and a
      // click that ends a text selection is not a choice.
      if (event.target.closest("a, input, label") || String(window.getSelection())) {
        return;
      }
      const radio = card.querySelector("[data-security-choice]");
      if (radio && !radio.checked) {
        radio.checked = true;
        radio.dispatchEvent(new Event("change", { bubbles: true }));
      }
    });
  });

  radios.forEach((radio) => radio.addEventListener("change", sync));

  // Form state survives a back-navigation, so start in step with it.
  sync();
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", setupSecurity);
} else {
  setupSecurity();
}

export default setupSecurity;
