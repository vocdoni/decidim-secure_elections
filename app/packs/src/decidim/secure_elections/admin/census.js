/**
 * Census admin: progressive enhancement, nothing load-bearing.
 *
 * Three things are enhanced here.
 *
 * 1. Voter authentication — cap the credentials at three the way the Vocdoni
 *    app does, keep the counter, the inline advice and the WEAK/MID/STRONG
 *    meter in step with the checkboxes, and reveal the "every member needs a
 *    contact" warning the moment 2FA is switched on.
 *
 * 2. The members table — add rows without a page load, and show a row that is
 *    on its way out as such before the census is saved.
 *
 * 3. The import panel — put the confirmation dialog on the submit button while
 *    "replace the current census" is ticked, and take it off again when it is
 *    not.
 *
 * Everything degrades. With JavaScript off the server renders the same
 * numbers, the same meter and one blank row, and a row is removed by ticking
 * its box and saving. Selectors are ids with a `js-` prefix or `data-`
 * attributes, never classes.
 */

const AUTH_WRAPPER_ID = "js-census-authentication";
const COUNT_ID = "js-census-credentials-count";
const TWO_FA_NOTE_ID = "js-census-two-factor-note";
const LIVE_METER_ID = "census-security-live";

const MEMBERS_WRAPPER_ID = "js-census-members";
const MEMBER_ROWS_ID = "js-census-members-rows";
const MEMBER_TEMPLATE_ID = "js-census-member-template";
const ADD_MEMBER_ID = "js-census-add-member";

const IMPORT_SUBMIT_ID = "js-census-import-submit";
const IMPORT_REPLACE_SELECTOR = "[data-census-import-replace]";

const AUTOSAVE_FORM_ID = "census-election-form";
const AUTOSAVE_INDICATOR_ID = "js-census-autosave-indicator";
const AUTOSAVE_DEBOUNCE_MS = 400;

const LEVELS = ["weak", "mid", "strong"];

/**
 * The Vocdoni app's rule, unchanged: two-factor wins outright, a full set of
 * credentials is mid, anything less is weak.
 * @param {boolean} twoFactor whether a second factor is configured.
 * @param {number} credentials how many credentials are ticked.
 * @param {number} max the credential cap.
 * @returns {string} "weak", "mid" or "strong".
 */
const securityLevel = (twoFactor, credentials, max) => {
  if (twoFactor) {
    return "strong";
  }
  return credentials >= max
    ? "mid"
    : "weak";
};

const setupAuthentication = () => {
  const wrapper = document.getElementById(AUTH_WRAPPER_ID);

  if (!wrapper) {
    return;
  }

  const max = parseInt(wrapper.dataset.maxCredentials, 10) || 3;
  const boxes = Array.from(wrapper.querySelectorAll("[data-census-credential]"));
  const radios = Array.from(wrapper.querySelectorAll("[data-census-two-factor]"));
  const counter = document.getElementById(COUNT_ID);
  const adviceBlocks = Array.from(wrapper.querySelectorAll("[data-census-advice]"));
  const twoFaNote = document.getElementById(TWO_FA_NOTE_ID);
  const meter = document.getElementById(LIVE_METER_ID);

  const selectedCount = () => boxes.filter((box) => box.checked).length;

  const twoFactorOn = () => radios.some((radio) => radio.checked && radio.dataset.censusTwoFactor !== "off");

  const applyLimit = (count) => {
    boxes.forEach((box) => {
      // Never disable a ticked box: the admin has to be able to change their
      // mind without first working out which one to untick.
      box.disabled = !box.checked && count >= max;
    });
  };

  const applyCounter = (count) => {
    if (!counter) {
      return;
    }
    counter.textContent = counter.dataset.template
      ? counter.dataset.template.replace("%selected%", count).replace("%max%", max)
      : `${count}/${max}`;
  };

  const applyAdvice = (count) => {
    // Both wordings were rendered by the server; the browser only decides
    // which is visible.
    let wanted = null;
    if (count === 1) {
      wanted = "recommend";
    } else if (count >= 2) {
      wanted = "good";
    }

    adviceBlocks.forEach((block) => {
      block.hidden = block.dataset.censusAdvice !== wanted;
    });
  };

  const applyTwoFaNote = () => {
    if (twoFaNote) {
      twoFaNote.hidden = !twoFactorOn();
    }
  };

  const applyMeter = (count) => {
    if (!meter) {
      return;
    }

    const level = securityLevel(twoFactorOn(), count, max);
    meter.dataset.securityLevel = level;

    LEVELS.forEach((value) => {
      const box = meter.querySelector(`[data-security-level-box="${value}"]`);
      if (box) {
        const active = value === level;
        box.className = active
          ? box.dataset.activeClass
          : box.dataset.inactiveClass;
        box.setAttribute("aria-current", String(active));
      }

      const summary = meter.querySelector(`[data-security-level-summary="${value}"]`);
      if (summary) {
        summary.hidden = value !== level;
      }
    });
  };

  const refresh = () => {
    const count = selectedCount();
    applyLimit(count);
    applyCounter(count);
    applyAdvice(count);
    applyTwoFaNote();
    applyMeter(count);
  };

  boxes.forEach((box) => box.addEventListener("change", refresh));
  radios.forEach((radio) => radio.addEventListener("change", refresh));

  refresh();
};

const setupMembers = () => {
  const wrapper = document.getElementById(MEMBERS_WRAPPER_ID);
  const rows = document.getElementById(MEMBER_ROWS_ID);
  const template = document.getElementById(MEMBER_TEMPLATE_ID);
  const addButton = document.getElementById(ADD_MEMBER_ID);

  if (!wrapper || !rows) {
    return;
  }

  // New rows continue the server-rendered numbering so no two rows submit
  // under the same key.
  let nextIndex = rows.querySelectorAll("[data-census-member-row]").length;

  const isPersisted = (row) => {
    const idField = row.querySelector('input[name$="[id]"]');
    return Boolean(idField) && idField.value !== "";
  };

  // A row on its way out stays where it is, dimmed, struck through, and
  // carrying a note that says so in words rather than in colour.
  //
  // It used to be hidden outright — `row.hidden = true` — which did nothing:
  // the stacked-table styles set a `display` on every `tr`, and any `display`
  // declaration beats the user-agent rule behind `hidden`. So ticking "Remove"
  // changed nothing on screen until the page was saved. Even working, hiding
  // was wrong: the tick is not submitted yet, so it has to be undoable, and a
  // row that has vanished cannot be unticked.
  const setRemoved = (row, removed) => {
    if (removed) {
      row.dataset.censusMemberRemoved = "true";
    } else {
      Reflect.deleteProperty(row.dataset, "censusMemberRemoved");
    }

    const note = row.querySelector("[data-census-member-removed-note]");
    if (note) {
      note.hidden = !removed;
    }
  };

  rows.addEventListener("change", (event) => {
    const flag = event.target.closest("[data-census-member-remove]");
    if (!flag) {
      return;
    }
    const row = flag.closest("[data-census-member-row]");
    if (!row) {
      return;
    }

    // A row that was never saved has nothing for the server to delete, so it
    // simply goes. Anything else is flagged and kept in the form.
    if (flag.checked && !isPersisted(row)) {
      row.remove();
    } else {
      setRemoved(row, flag.checked);
    }
  });

  if (!addButton || !template) {
    return;
  }

  addButton.addEventListener("click", () => {
    const html = template.innerHTML.
      replace(/%index%/gu, String(nextIndex)).
      replace(/%row%/gu, String(nextIndex + 1));
    nextIndex += 1;

    const holder = document.createElement("tbody");
    holder.innerHTML = html.trim();
    const row = holder.querySelector("tr");

    if (!row) {
      return;
    }

    rows.appendChild(row);

    // Land the caret in the new row: adding a person and then having to find
    // where to type is the friction this button exists to remove.
    const firstInput = row.querySelector("input:not([type=hidden]):not([type=checkbox])");
    if (firstInput) {
      firstInput.focus();
    }
  });
};

/**
 * "Replace the current census" is the one routine action on this screen that
 * destroys data, and it had no confirmation of any kind.
 *
 * The `data-confirm` was on the checkbox, where nothing reads it: Decidim's
 * confirm dialog listens for clicks on links, submit buttons and form
 * submits, and a checkbox is none of those. The confirmation belongs on the
 * submit button — but only while the box is ticked, which is something only
 * the browser knows. So the message is carried on the checkbox and moved onto
 * the button whenever the box changes.
 *
 * The dialog itself takes `data-confirm`, `data-confirm-title` and
 * `data-confirm-icon` and nothing else; its buttons are its own.
 */
const setupImport = () => {
  const replaceBox = document.querySelector(IMPORT_REPLACE_SELECTOR);
  const submit = document.getElementById(IMPORT_SUBMIT_ID);

  if (!replaceBox || !submit) {
    return;
  }

  const sync = () => {
    if (replaceBox.checked) {
      submit.dataset.confirm = replaceBox.dataset.confirmMessage || "";
      submit.dataset.confirmTitle = replaceBox.dataset.confirmTitle || "";
    } else {
      Reflect.deleteProperty(submit.dataset, "confirm");
      Reflect.deleteProperty(submit.dataset, "confirmTitle");
    }
  };

  replaceBox.addEventListener("change", sync);

  // The box survives a back-navigation with its state restored, so the button
  // has to start in step with it rather than assume it is unticked.
  sync();
};

/**
 * Persist the credentials + 2FA form the moment a checkbox is ticked or a
 * radio switched. There is no Save button on this half of the tab any more:
 * the import and verifications panels below both validate against
 * `election.auth_fields`, so an admin who typed nothing but ticked a
 * credential and moved on to Import used to see the import refuse rows
 * because the credential had never been saved. Auto-saving the auth form
 * lifts that failure mode and matches how the Vocdoni app dialog behaves.
 *
 * The submit is a plain `fetch` with `Accept: application/json`. The
 * controller returns `{ status: "ok" }` on success and `{ status: "invalid",
 * errors: [...] }` with 422 on failure; the pack reads the status alone and
 * rotates the indicator between four labels the server rendered next to the
 * form. Debounced at 400ms so ticking three boxes in quick succession is
 * still one save. Requests are serialised: a save that is in flight when a
 * new change arrives is left to finish, and the next debounce fires from
 * there — this is what keeps the server from being asked to persist a form
 * that is already stale.
 */
const setupAutoSave = () => {
  const form = document.getElementById(AUTOSAVE_FORM_ID);
  const indicator = document.getElementById(AUTOSAVE_INDICATOR_ID);

  if (!form || !indicator) {
    return;
  }

  const setState = (state) => {
    const label = indicator.dataset[`${state}Label`];
    if (label) {
      indicator.textContent = label;
    }
  };

  let inFlight = null;
  let queued = false;

  const submit = async () => {
    if (inFlight) {
      queued = true;
      return;
    }

    setState("saving");
    const body = new FormData(form);

    inFlight = fetch(form.action, {
      method: form.method || "post",
      body,
      credentials: "same-origin",
      headers: { Accept: "application/json", "X-Requested-With": "XMLHttpRequest" },
    }).then((response) => {
      setState(response.ok ? "saved" : "error");
    }).catch(() => {
      setState("error");
    }).finally(() => {
      inFlight = null;
      if (queued) {
        queued = false;
        submit();
      }
    });
  };

  let timer = null;
  const debouncedSubmit = () => {
    clearTimeout(timer);
    timer = setTimeout(submit, AUTOSAVE_DEBOUNCE_MS);
  };

  form.addEventListener("change", debouncedSubmit);
};

const setupCensusAdmin = () => {
  setupAuthentication();
  setupMembers();
  setupImport();
  setupAutoSave();
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", setupCensusAdmin);
} else {
  setupCensusAdmin();
}

export default setupCensusAdmin;
