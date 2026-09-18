/**
 * "Participants from a file": the card on the Census tab.
 *
 * Progressive enhancement, nothing load-bearing. Without any of this the
 * admin picks a file and presses Upload, and the server pre-selects a
 * suggestion per column, derives the details voters type and validates the
 * lot on submit. This only spares them the round trips.
 *
 * 1. Choosing a file uploads it, so the drop zone is one gesture rather than
 *    two. The fallback button is hidden only once that is wired up.
 * 2. Dropping a file on the zone does the same.
 * 3. A detail chosen for one column is disabled in every other column's
 *    select, so an admin cannot point two columns at "Email" without a
 *    round trip to find out.
 * 4. The details a voter can be asked for are the columns being kept, so
 *    they follow the same selects: a column dropped here stops being
 *    offered, and one just mapped becomes available at once.
 * 5. The sentence above "Change" follows the boxes, so the summary and the
 *    detail never disagree while the admin is looking at both.
 */

const COLUMN_TABLE_SELECTOR = "[data-column-table]";
const IDENTIFIERS_ID = "js-census-identifiers";
const SELECT_SELECTOR = "[data-column-select]";

// Submitting on choose is what removes the second click. `requestSubmit`
// rather than `submit`: it runs the form's own validation and events, as a
// real button press would.
const setupUpload = () => {
  document.querySelectorAll("[data-upload-form]").forEach((form) => {
    const input = form.querySelector("[data-upload-input]");
    const zone = form.querySelector("[data-dropzone]");

    if (!input) {
      return;
    }

    form.querySelectorAll("[data-upload-fallback]").forEach((element) => {
      element.hidden = true;
    });

    input.addEventListener("change", () => {
      if (input.files && input.files.length > 0) {
        form.requestSubmit();
      }
    });

    if (!zone) {
      return;
    }

    ["dragenter", "dragover"].forEach((name) => {
      zone.addEventListener(name, (event) => {
        event.preventDefault();
        zone.classList.add("is-dragging");
      });
    });

    ["dragleave", "dragend", "drop"].forEach((name) => {
      zone.addEventListener(name, () => zone.classList.remove("is-dragging"));
    });

    zone.addEventListener("drop", (event) => {
      event.preventDefault();
      const dropped = event.dataTransfer && event.dataTransfer.files;
      if (!dropped || dropped.length === 0) {
        return;
      }
      input.files = dropped;
      form.requestSubmit();
    });
  });
};

const setupCensusFileMapping = () => {
  // Columns to place live in two tables on the same card: the ones we could
  // not recognise, and the rest behind a disclosure, so every select is
  // collected, not just the first table's.
  const tables = Array.from(document.querySelectorAll(COLUMN_TABLE_SELECTOR));
  const identifiers = document.getElementById(IDENTIFIERS_ID);

  // The review state has both; the list state has the second one alone, with
  // its columns already settled.
  if (tables.length === 0 && !identifiers) {
    return;
  }

  const selects = tables.flatMap((table) => Array.from(table.querySelectorAll(SELECT_SELECTOR)));

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

  const identifierItems = identifiers
    ? Array.from(identifiers.querySelectorAll("[data-identifier]"))
    : [];

  // Only the part of the sentence that lists the details. Everything around
  // it (what a code does, what an access code cannot do) depends on the vote
  // type and stays as the server wrote it until the page is saved.
  const syncSentence = (chosen) => {
    const target = document.querySelector("[data-identifiers-sentence] [data-identifiers-names]");
    if (!target) {
      return;
    }
    const names = chosen.
      map((item) => {
        return item.dataset.identifierSentence || "";
      }).
      filter(Boolean);

    if (names.length > 0) {
      target.textContent = names.join(", ");
    }
  };

  const syncIdentifiers = (rewriteSentence) => {
    if (!identifiers) {
      return;
    }

    const kept = selects.map((select) => select.value).filter(Boolean);

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

    identifiers.querySelectorAll("[data-identifiers-empty]").forEach((element) => {
      element.hidden = visible.length > 0;
    });

    const weakFields = (identifiers.dataset.weak || "").split(" ").filter(Boolean);
    const weak = chosen.length > 0 && chosen.every((item) => weakFields.includes(item.dataset.identifier));
    identifiers.querySelectorAll("[data-identifiers-weak]").forEach((element) => {
      element.hidden = !weak;
    });

    if (rewriteSentence) {
      syncSentence(chosen);
    }
  };

  // The server already wrote the sentence, in the reader's language and with
  // its conjunction. Rewriting it on load would replace "email and access
  // code" with a comma; only an actual change is worth catching up with.
  let touched = false;

  const sync = () => {
    syncOptions();
    syncIdentifiers(touched);
  };

  const syncAfterChange = () => {
    touched = true;
    sync();
  };

  selects.forEach((select) => select.addEventListener("change", syncAfterChange));
  identifierItems.forEach((item) => {
    item.querySelector("input[type=checkbox]").addEventListener("change", syncAfterChange);
  });

  sync();
};

const setupCensusFile = () => {
  setupUpload();
  setupCensusFileMapping();
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", setupCensusFile);
} else {
  setupCensusFile();
}

export default setupCensusFile;
