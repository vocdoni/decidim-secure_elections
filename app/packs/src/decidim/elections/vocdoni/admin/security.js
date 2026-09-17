/**
 * Security tab: progressive enhancement, nothing load-bearing.
 *
 * The server renders every state from what is saved. This keeps the page in
 * step while the admin changes things without saving:
 *
 * 1. The whole vote-type card selects its option, and the selected card is
 *    highlighted (browsers without `:has()`). Without JavaScript the radio
 *    and the card title still do.
 * 2. The one-time code card is only usable while the secret vote is
 *    selected.
 * 3. The identifiers of a file census follow the vote type (the secure
 *    service accepts fewer details), stop at the maximum, and warn when the
 *    choice is easy to guess.
 * 4. The summary line follows the selection.
 *
 * All copy comes from the page; selectors are ids with a `js-` prefix or
 * `data-` attributes, never classes.
 */

const CHOICE_ID = "js-security-choice";
const TWO_FACTOR_ID = "js-security-two-factor";
const SUMMARY_ID = "js-security-summary";
const IDENTIFIERS_ID = "js-security-identifiers";

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
  const twoFactor = document.getElementById(TWO_FACTOR_ID);
  const summary = document.getElementById(SUMMARY_ID);

  if (!choice || !twoFactor) {
    return;
  }

  const radios = Array.from(choice.querySelectorAll("[data-security-choice]"));
  const cards = Array.from(choice.querySelectorAll("[data-security-choice-card]"));
  const codes = Array.from(twoFactor.querySelectorAll("[data-security-code]"));
  const notes = Array.from(twoFactor.querySelectorAll("[data-two-factor-note]"));

  const identifiers = document.getElementById(IDENTIFIERS_ID);
  const identifierItems = identifiers
    ? Array.from(identifiers.querySelectorAll("[data-identifier]"))
    : [];
  const registeredNotes = Array.from(document.querySelectorAll("[data-identifiers-note]"));

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

  const syncTwoFactor = (value) => {
    const usable = value === "secure";
    twoFactor.disabled = !usable;
    notes.forEach((element) => {
      element.hidden = usable;
    });

    return usable && codes.some((box) => box.checked && !box.disabled);
  };

  // Which boxes the vote type allows, then the maximum: once it is reached
  // the other allowed boxes are disabled too, so the limit explains itself.
  const syncIdentifiers = (value, oneTimeCode) => {
    registeredNotes.forEach((element) => {
      element.hidden = element.dataset.identifiersNote !== value;
    });

    if (!identifiers) {
      return;
    }

    const max = parseInt(identifiers.dataset.max, 10) || 3;
    const weakFields = (identifiers.dataset.weak || "").split(" ");
    const allowed = (item) => item.dataset[value === "secure"
      ? "secureOk"
      : "simpleOk"] === "true";

    // A detail the secret vote refuses is unticked while it is refused and
    // ticked again when the admin goes back to a simple vote.
    identifierItems.forEach((item) => {
      const box = item.querySelector("input[type=checkbox]");
      const ok = allowed(item);
      if (!ok && box.checked) {
        box.checked = false;
        item.dataset.wasChecked = "true";
      } else if (ok && item.dataset.wasChecked === "true") {
        box.checked = true;
        Reflect.deleteProperty(item.dataset, "wasChecked");
      }
      item.classList.toggle("is-unavailable", !ok);
      item.querySelectorAll("[data-identifier-hint=refused]").forEach((hint) => {
        hint.hidden = ok;
      });
    });

    const chosen = identifierItems.filter((item) => item.querySelector("input[type=checkbox]").checked);
    identifierItems.forEach((item) => {
      const box = item.querySelector("input[type=checkbox]");
      box.disabled = !allowed(item) || (!box.checked && chosen.length >= max);
    });

    const weak = chosen.length > 0 &&
      chosen.every((item) => weakFields.includes(item.dataset.identifier)) &&
      !oneTimeCode;
    identifiers.querySelectorAll("[data-identifiers-weak]").forEach((element) => {
      element.hidden = !weak;
    });
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
    const oneTimeCode = syncTwoFactor(value);
    syncIdentifiers(value, oneTimeCode);
    syncSummary(securityLevel(value, oneTimeCode));
  };

  cards.forEach((card) => {
    card.addEventListener("click", (event) => {
      // Links, the radio and its label already do their own thing, and a
      // click that ends a text selection is not a choice.
      if (event.target.closest("a, input, label") || String(window.getSelection()) || card.classList.contains("is-unavailable")) {
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
  identifierItems.forEach((item) => {
    item.querySelector("input[type=checkbox]").addEventListener("change", sync);
  });

  // Form state survives a back-navigation, so start in step with it.
  sync();
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", setupSecurity);
} else {
  setupSecurity();
}

export default setupSecurity;
