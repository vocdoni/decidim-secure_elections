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

// Mirror what the current question title looks like into the collapsed
// card header. Upstream's LiveTextUpdateComponent reads the
// preview's data-attributes then binds to `input[name$="[body_{locale}]"]`
// — that regex is baked into decidim-forms, and our field is `[title]`
// instead of `[body]`, so upstream's binding matches nothing and the
// preview stays stuck on the placeholder. Wire the same update loop
// ourselves against our field naming, with a delegated input listener
// on the questions list so it also catches cards `createEditableForm`
// clones in for Add question.
const paintTitlePreview = (card) => {
  const preview = card.querySelector(".question-title-statement");
  if (!preview) {
    return;
  }
  const locale = preview.dataset.locale || "en";
  const input = card.querySelector(`input[name$="[title][${locale}]"]`);
  if (!input) {
    return;
  }
  const placeholder = preview.dataset.placeholder || "";
  const maxLength = parseInt(preview.dataset.maxLength, 10) || 0;
  const omission = preview.dataset.omission || "…";
  let text = input.value || placeholder;
  if (maxLength > 0 && text.length > maxLength) {
    text = `${text.substring(0, maxLength - omission.length)}${omission}`;
  }
  preview.textContent = text;
};

const wireTitlePreviews = () => {
  const list = document.getElementById("questionnaire-questions-list");
  if (!list) {
    return;
  }
  list.querySelectorAll(".card.questionnaire-question").forEach(paintTitlePreview);
  list.addEventListener("input", (event) => {
    const card = event.target.closest(".card.questionnaire-question");
    if (card) {
      paintTitlePreview(card);
    }
  });
  // Paint newly-cloned cards the moment createEditableForm inserts them.
  const observer = new MutationObserver((mutations) => {
    for (const mutation of mutations) {
      mutation.addedNodes.forEach((node) => {
        if (node.nodeType !== Node.ELEMENT_NODE) {
          return;
        }
        if (node.matches?.(".card.questionnaire-question")) {
          paintTitlePreview(node);
        }
        node.querySelectorAll?.(".card.questionnaire-question").forEach(paintTitlePreview);
      });
    }
  });
  observer.observe(list, { childList: true, subtree: false });
};

// createEditableForm wires two upstream FieldDependentInputsComponent
// instances per question card: one that shows the response-options
// section when the question_type is in ["single_option",
// "multiple_option", "sorting", "matrix_single", "matrix_multiple"]
// (see `re` in decidim_forms_admin.js), and another that shows the
// max_choices select only when the value is "multiple_option" or
// "matrix_multiple". Our question_type values are "singlechoice" and
// "multichoice" — the enclosing Vochain rejects camelCase with error
// 40037 and the underscore convention is not portable — so both
// enablingConditions return false unconditionally, and both sections
// stay display:none for every card.
//
// The upstream handlers run on the same `change` event, so a later
// listener wins the last write. We register ours after
// createEditableForm has bound its own, and drive it directly from our
// two values: response-options is always visible (every question in our
// data model carries answers), max_choices is visible only when the
// question is multichoice.
const applyQuestionTypeVisibility = (card) => {
  const select = card.querySelector('select[name$="[question_type]"]');
  if (!select) {
    return;
  }
  const responseOptions = card.querySelector(".questionnaire-question-response-options");
  const maxChoices = card.querySelector(".questionnaire-question-max-choices");
  const setVisible = (element, visible) => {
    if (!element) {
      return;
    }
    if (visible) {
      element.classList.remove("hidden");
      element.style.display = "";
    } else {
      element.classList.add("hidden");
      element.style.display = "none";
    }
  };
  const apply = () => {
    setVisible(responseOptions, true);
    setVisible(maxChoices, select.value === "multichoice");
  };
  select.addEventListener("change", apply);
  apply();
};

const wireQuestionTypeVisibility = () => {
  const list = document.getElementById("questionnaire-questions-list");
  if (!list) {
    return;
  }
  list.querySelectorAll(".card.questionnaire-question").forEach(applyQuestionTypeVisibility);
  const observer = new MutationObserver((mutations) => {
    for (const mutation of mutations) {
      mutation.addedNodes.forEach((node) => {
        if (node.nodeType !== Node.ELEMENT_NODE) {
          return;
        }
        if (node.matches?.(".card.questionnaire-question")) {
          applyQuestionTypeVisibility(node);
        }
        node.querySelectorAll?.(".card.questionnaire-question").forEach(applyQuestionTypeVisibility);
      });
    }
  });
  observer.observe(list, { childList: true, subtree: false });
};

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
  wireTitlePreviews();
  wireQuestionTypeVisibility();
};

document.addEventListener("turbo:load", bootstrap);
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", bootstrap);
} else {
  bootstrap();
}
