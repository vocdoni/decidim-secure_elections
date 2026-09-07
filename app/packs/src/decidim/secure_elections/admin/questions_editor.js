/**
 * Questions tab editor bootstrapper.
 *
 * Delegates all question-card behaviour (drag-reorder via html5sortable,
 * clone-from-template via DynamicFieldsComponent, soft-delete via the
 * hidden `deleted` field) to upstream's createEditableForm() from
 * decidim-forms, exactly as decidim-elections does.
 *
 * The upstream pack (`decidim_forms_admin`) exposes createEditableForm on
 * `window.Decidim`; we defer to that instead of importing the module
 * directly, because the module lives inside the Decidim gem tree and the
 * import path Shakapacker resolves it under is not the same as the one
 * ESLint sees from this checkout. The view is responsible for appending
 * `decidim_forms_admin` so the function exists by the time this runs.
 *
 * The guard on .questionnaire-questions means this is a no-op on every
 * other admin page.
 *
 * We listen on `turbo:load` for a Turbo Drive navigation AND
 * `DOMContentLoaded` for a full page load, because the Decidim
 * application this module ships into (the reference deployment behind
 * decidim.vocdoni.io) doesn't include Turbo. `turbo:load` never fires
 * there and createEditableForm never runs — Add response option and
 * Add question look bound but do nothing. A `bootstrapped` flag on the
 * container keeps the two listeners from double-initialising the JS
 * when both events do fire.
 */

const bootstrap = () => {
  const container = document.querySelector(".questionnaire-questions");
  if (!container || container.dataset.bootstrapped === "true") {
    return;
  }
  const createEditableForm = window.Decidim && window.Decidim.createEditableForm;
  if (typeof createEditableForm !== "function") {
    return;
  }
  container.dataset.bootstrapped = "true";
  createEditableForm();
};

document.addEventListener("turbo:load", bootstrap);
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", bootstrap);
} else {
  bootstrap();
}
