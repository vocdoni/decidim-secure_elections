/**
 * "Participants from a file" — the import page, once a file has been read.
 *
 * Progressive enhancement, nothing load-bearing: the server already
 * pre-selects a suggestion per column and validates duplicates and missing
 * identity fields on submit, so this only makes the common mistakes harder
 * to make in the first place.
 *
 * 1. A detail chosen for one column is disabled in every other column's
 *    select, so an admin cannot point two columns at "Email" without the
 *    server round-trip that would otherwise be the only way to find out.
 * 2. The "keep at least one identity detail" hint follows the current
 *    selections rather than only the page's initial state.
 * 3. The details a voter can be asked for are the columns being kept, so
 *    they follow the same selects — a column dropped here stops being
 *    offered, and one just mapped becomes available without a round trip.
 *    The maximum is enforced the same way the Security tab did it: once it
 *    is reached the remaining boxes are disabled, so the limit explains
 *    itself. The server checks all of this again.
 */

const COLUMN_TABLE_SELECTOR = "[data-column-table]";
const IDENTITY_HINT_ID = "js-census-file-identity-hint";
const IDENTIFIERS_ID = "js-census-identifiers";
const SELECT_SELECTOR = "[data-column-select]";

const setupCensusFileMapping = () => {
  // Columns to place live in two tables on the same page — the ones we could
  // not recognise, and the rest behind a disclosure — so every select is
  // collected, not just the first table's.
  const tables = Array.from(document.querySelectorAll(COLUMN_TABLE_SELECTOR));
  const identityHint = document.getElementById(IDENTITY_HINT_ID);
  const identifiers = document.getElementById(IDENTIFIERS_ID);

  // The import page has both; the page that only changes the details a voter
  // types has the second one alone, with its columns already settled.
  if (tables.length === 0 && !identifiers) {
    return;
  }

  const selects = tables.flatMap((table) => Array.from(table.querySelectorAll(SELECT_SELECTOR)));
  const identityFields = ((tables[0] && tables[0].dataset.identityFields) || "").split(" ").filter(Boolean);

  const chosenValues = (except) => selects.
    filter((select) => select !== except).
    map((select) => select.value).
    filter(Boolean);

  const syncOptions = () => {
    selects.forEach((select) => {
      const taken = chosenValues(select);
      Array.from(select.options).forEach((option) => {
        if (!option.value) {
          return;
        }
        option.disabled = taken.includes(option.value) && option.value !== select.value;
      });
    });
  };

  const syncIdentityHint = () => {
    if (!identityHint) {
      return;
    }
    const chosen = selects.map((select) => select.value).filter(Boolean);
    const hasIdentity = chosen.some((value) => identityFields.includes(value));
    identityHint.hidden = hasIdentity;
  };

  const identifierItems = identifiers
    ? Array.from(identifiers.querySelectorAll("[data-identifier]"))
    : [];

  const syncIdentifiers = () => {
    if (!identifiers) {
      return;
    }

    const kept = selects.map((select) => select.value).filter(Boolean);
    const max = parseInt(identifiers.dataset.max, 10) || 3;

    identifierItems.forEach((item) => {
      const box = item.querySelector("input[type=checkbox]");
      // With no columns to follow, every rendered detail is one the list has.
      const available = tables.length > 0
        ? kept.includes(item.dataset.identifier)
        : true;
      item.hidden = !available;
      // A detail whose column was dropped cannot be asked for.
      if (!available && box.checked) {
        box.checked = false;
      }
    });

    const visible = identifierItems.filter((item) => !item.hidden);
    const chosen = visible.filter((item) => item.querySelector("input[type=checkbox]").checked);
    visible.forEach((item) => {
      const box = item.querySelector("input[type=checkbox]");
      box.disabled = !box.checked && chosen.length >= max;
    });

    identifiers.querySelectorAll("[data-identifiers-empty]").forEach((element) => {
      element.hidden = visible.length > 0;
    });

    const weakFields = (identifiers.dataset.weak || "").split(" ").filter(Boolean);
    const weak = chosen.length > 0 && chosen.every((item) => weakFields.includes(item.dataset.identifier));
    identifiers.querySelectorAll("[data-identifiers-weak]").forEach((element) => {
      element.hidden = !weak;
    });
  };

  const sync = () => {
    syncOptions();
    syncIdentityHint();
    syncIdentifiers();
  };

  selects.forEach((select) => select.addEventListener("change", sync));
  identifierItems.forEach((item) => {
    item.querySelector("input[type=checkbox]").addEventListener("change", sync);
  });

  sync();
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", setupCensusFileMapping);
} else {
  setupCensusFileMapping();
}

export default setupCensusFileMapping;
