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
 *    the secret vote is selected.
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

    // Hidden and disabled together: a disabled fieldset submits nothing, so
    // a simple vote never carries a stale code choice.
    const usable = value === "secure";
    twoFactor.hidden = !usable;
    twoFactor.disabled = !usable;
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
