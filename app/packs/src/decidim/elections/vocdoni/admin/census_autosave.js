/**
 * Persist the credentials + 2FA form the moment a checkbox is ticked or a
 * radio switched. There is no Save button on this half of the Census tab
 * any more: the import and verifications panels below both validate against
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

const AUTOSAVE_FORM_ID = "census-election-form";
const AUTOSAVE_INDICATOR_ID = "js-census-autosave-indicator";
const AUTOSAVE_DEBOUNCE_MS = 400;

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
    const headers = {
      Accept: "application/json",
      "X-Requested-With": "XMLHttpRequest"
    };

    inFlight = fetch(form.action, {
      method: form.method || "post",
      body,
      credentials: "same-origin",
      headers
    }).then((response) => {
      if (response.ok) {
        setState("saved");
      } else {
        setState("error");
      }
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

export default setupAutoSave;
