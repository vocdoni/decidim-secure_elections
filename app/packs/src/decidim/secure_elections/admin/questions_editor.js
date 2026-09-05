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
 */

document.addEventListener("turbo:load", () => {
  if (!document.querySelector(".questionnaire-questions")) {
    return;
  }
  const createEditableForm = window.Decidim && window.Decidim.createEditableForm;
  if (typeof createEditableForm === "function") {
    createEditableForm();
  }
});
