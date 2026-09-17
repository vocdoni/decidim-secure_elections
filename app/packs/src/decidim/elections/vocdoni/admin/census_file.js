/**
 * "Participants from a file" — wizard step 2 (matching columns).
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
 */

const MAPPING_TABLE_ID = "js-census-file-mapping-table";
const IDENTITY_HINT_ID = "js-census-file-identity-hint";
const SELECT_SELECTOR = "[data-column-select]";

const setupCensusFileMapping = () => {
  const table = document.getElementById(MAPPING_TABLE_ID);
  const identityHint = document.getElementById(IDENTITY_HINT_ID);

  if (!table) {
    return;
  }

  const selects = Array.from(table.querySelectorAll(SELECT_SELECTOR));
  const identityFields = (table.dataset.identityFields || "").split(" ").filter(Boolean);

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

  const sync = () => {
    syncOptions();
    syncIdentityHint();
  };

  selects.forEach((select) => select.addEventListener("change", sync));

  sync();
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", setupCensusFileMapping);
} else {
  setupCensusFileMapping();
}

export default setupCensusFileMapping;
