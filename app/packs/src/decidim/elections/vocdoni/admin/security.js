/**
 * Security tab: progressive enhancement, nothing load-bearing.
 *
 * The server renders every state from what is saved. This keeps the page in
 * step while the admin changes things without saving:
 *
 * 1. The whole vote-type card selects its option, and the selected card is
 *    highlighted (browsers without `:has()`). Without JavaScript the radio
 *    and the card title still do.
 * 2. The auth-fields card and the one-time code card are only usable while
 *    the secret vote is selected.
 * 3. The summary line follows the selection.
 *
 * All copy comes from the page; selectors are ids with a `js-` prefix or
 * `data-` attributes, never classes.
 */

const CHOICE_ID = "js-security-choice";
const AUTH_FIELDS_ID = "js-security-auth-fields";
const TWO_FACTOR_ID = "js-security-two-factor";
const SUMMARY_ID = "js-security-summary";

/**
 * Mirrors `SecurityForm#level`.
 * @param {string} choice "simple" or "secure".
 * @param {boolean} oneTimeCode whether a one-time code (email or SMS) will be sent.
 * @returns {string} "basic", "strong" or "strongest".
 */
const securityLevel = (choice, oneTimeCode) => {
  if (choice !== "secure") {
    return "basic";
  }
  return oneTimeCode
    ? "strongest"
    : "strong";
};

const setupSecurity = () => {
  const choice = document.getElementById(CHOICE_ID);
  const authFields = document.getElementById(AUTH_FIELDS_ID);
  const twoFactor = document.getElementById(TWO_FACTOR_ID);
  const summary = document.getElementById(SUMMARY_ID);

  if (!choice || !twoFactor) {
    return;
  }

  const radios = Array.from(choice.querySelectorAll("[data-security-choice]"));
  const cards = Array.from(choice.querySelectorAll("[data-security-choice-card]"));
  const codes = Array.from(twoFactor.querySelectorAll("[data-security-code]"));
  const notes = Array.from(twoFactor.querySelectorAll("[data-two-factor-note]"));
  const authNotes = authFields
    ? Array.from(authFields.querySelectorAll("[data-auth-fields-note]"))
    : [];

  const selected = () => {
    const radio = radios.find((input) => input.checked);
    return radio
      ? radio.dataset.securityChoice
      : "";
  };

  const syncCards = (value) => {
    cards.forEach((card) => {
      card.classList.toggle("is-selected", card.dataset.securityChoiceCard === value);
    });
  };

  const syncAuthFields = (value) => {
    if (!authFields) {
      return;
    }
    const usable = value === "secure";
    authFields.disabled = !usable;
    authNotes.forEach((element) => {
      element.hidden = usable;
    });
  };

  const syncTwoFactor = (value) => {
    const usable = value === "secure";
    twoFactor.disabled = !usable;
    notes.forEach((element) => {
      element.hidden = usable;
    });

    return usable && codes.some((box) => box.checked);
  };

  const syncSummary = (level) => {
    if (!summary) {
      return;
    }
    summary.querySelectorAll("[data-security-level]").forEach((element) => {
      element.hidden = element.dataset.securityLevel !== level;
    });
    summary.querySelectorAll("[data-security-sentence]").forEach((element) => {
      element.hidden = element.dataset.securitySentence !== level;
    });
  };

  const sync = () => {
    const value = selected();
    syncCards(value);
    syncAuthFields(value);
    syncSummary(securityLevel(value, syncTwoFactor(value)));
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
  codes.forEach((box) => box.addEventListener("change", sync));

  // Form state survives a back-navigation, so start in step with it.
  sync();
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", setupSecurity);
} else {
  setupSecurity();
}

export default setupSecurity;
