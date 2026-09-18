/**
 * Census tab: progressive enhancement, nothing load-bearing.
 *
 * The server renders both set-up blocks and the saved choice. This keeps the
 * page in step while the admin changes things without saving:
 *
 * 1. The whole census-type card selects its option, and only the set-up block
 *    of the selected type is shown. Without JavaScript the radio and its title
 *    still select, and both blocks are visible: nothing becomes unreachable.
 * 2. The Save button says why it does nothing until a type is chosen.
 * 3. A ticked verification reveals its options (upstream did this with an
 *    inline <script> in its own partial, which this page does not render).
 *
 * The warning about a list being removed is not here on purpose: it is
 * rendered on the card, so an admin sees it whether or not this file ran.
 *
 * All copy comes from the page; selectors are ids with a `js-` prefix or
 * `data-` attributes, never classes.
 */

const CHOICE_ID = "js-census-choice";
const SUBMIT_ID = "js-census-submit";
const HINT_ID = "js-census-save-hint";

const setupCensus = () => {
  const choice = document.getElementById(CHOICE_ID);

  if (!choice) {
    return;
  }

  const radios = Array.from(choice.querySelectorAll("[data-census-choice]"));
  const cards = Array.from(choice.querySelectorAll("[data-census-choice-card]"));
  const blocks = Array.from(document.querySelectorAll("[data-census-block]"));
  const submit = document.getElementById(SUBMIT_ID);
  const hint = document.getElementById(HINT_ID);

  const selected = () => {
    const radio = radios.find((input) => input.checked);
    return radio
      ? radio.dataset.censusChoice
      : "";
  };

  const sync = () => {
    const value = selected();

    cards.forEach((card) => {
      card.classList.toggle("is-selected", card.dataset.censusChoiceCard === value);
    });

    blocks.forEach((block) => {
      block.hidden = block.dataset.censusBlock !== value;
    });

    if (submit) {
      submit.setAttribute("aria-disabled", String(value === ""));

      // Saving any census other than the uploaded list deletes it. The card
      // says so in words for everyone; here it also has to be agreed to.
      const voters = parseInt(submit.dataset.voters, 10) || 0;
      if (voters > 0 && value !== "" && value !== "token_csv") {
        submit.setAttribute("data-confirm", submit.dataset.confirmBody);
      } else {
        submit.removeAttribute("data-confirm");
      }
    }

    if (hint) {
      hint.hidden = value !== "";
    }
  };

  cards.forEach((card) => {
    card.addEventListener("click", (event) => {
      // Links, the radio and its label already do their own thing, and a
      // click that ends a text selection is not a choice.
      if (event.target.closest("a, input, label") || String(window.getSelection())) {
        return;
      }
      const radio = card.querySelector("[data-census-choice]");
      if (radio && !radio.checked) {
        radio.checked = true;
        radio.dispatchEvent(new Event("change", { bubbles: true }));
      }
    });
  });

  radios.forEach((radio) => radio.addEventListener("change", sync));

  // A save with no census type chosen would reach an upstream action that
  // assumes one; the server answers it too, this only saves the round trip.
  if (submit) {
    submit.addEventListener("click", (event) => {
      if (submit.getAttribute("aria-disabled") === "true") {
        event.preventDefault();
        radios[0]?.focus();
      }
    });
  }

  // Verification options follow their checkbox.
  document.querySelectorAll("[data-verification] input[type=checkbox]").forEach((box) => {
    const row = box.closest("[data-verification]");
    const options = row && row.querySelector("[data-verification-options]");
    if (!options) {
      return;
    }
    box.addEventListener("change", () => {
      options.hidden = !box.checked;
    });
  });

  // Form state survives a back-navigation, so start in step with it.
  sync();
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", setupCensus);
} else {
  setupCensus();
}

export default setupCensus;
