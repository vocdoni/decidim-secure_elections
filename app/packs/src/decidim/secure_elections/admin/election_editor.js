/* eslint-disable max-lines */
//
// Over the 300-line limit on purpose, the same way — and for the same reason —
// as `decidim-forms/app/packs/src/decidim/forms/admin/forms.js`, which is the
// equivalent editor in core and carries the same disable. The length is one
// cohesive class, not accumulated cruft: splitting it would mean handing pieces
// of a single DOM contract to separate modules that all have to agree on the
// same data attributes, which is harder to follow than the class is.

/**
 * The editing behaviour of the election wizard steps.
 *
 * One class serves three steps, because each of them wants a subset of the same
 * behaviour and none of them wants all of it:
 *
 * - **details** — autosave and the leave confirmation;
 * - **questions** — the whole of it: add, remove and reorder questions and
 *   options without a page load, the process-wide question type, autosave;
 * - **calendar** — the "start immediately" toggle.
 *
 * Every part is therefore optional. A step that does not render the question
 * list gets a class that quietly does nothing about questions, rather than a
 * second entry point to keep in step with this one.
 *
 * Everything here is progressive enhancement over a form that already works
 * without JavaScript: the server renders the questions and options it has, and
 * accepts whatever comes back. What this file adds is the thing a page-per-step
 * wizard could not do — adding a question or an option without a page load —
 * plus the draft autosave and the leave confirmation the Vocdoni app has.
 *
 * Design notes worth keeping in mind while reading:
 *
 * - New rows are cloned from `<template>` elements the server rendered. Their
 *   content is inert until inserted, so nothing inside them is submitted, no
 *   Stimulus controller connects, and no duplicate DOM id exists in the
 *   meantime. `__QIDX__` / `__AIDX__` placeholders appear in the `name`, the
 *   `id` and the `uid` alike, so a single substitution keeps all three
 *   consistent.
 * - Indices only have to be unique, never contiguous. The on-chain position of
 *   a question and the choice value of an option are both derived from DOM
 *   order when the election is saved, so reordering is a plain node move.
 * - Every mutation is announced through one live region. Add, remove and move
 *   are invisible to a screen reader otherwise.
 */

const PLACEHOLDER_QUESTION = /__QIDX__/g;
const PLACEHOLDER_OPTION = /__AIDX__/g;
const BLUR_SAVE_DELAY = 1500;
// Mirrors `QuestionForm::MINIMUM_OPTIONS`: fewer than two options is not a choice.
const MINIMUM_OPTIONS = 2;

const parseTemplate = (html) => {
  const holder = document.createElement("template");
  holder.innerHTML = html.trim();
  return holder.content.firstElementChild;
};

const csrfToken = () => document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || "";

class ElectionEditor {
  constructor(root) {
    this.root = root;
    this.form = root.closest("form");
    this.status = root.querySelector("[data-vocdoni-status]");
    this.questionList = root.querySelector("[data-vocdoni-questions]");
    this.questionTemplate = root.querySelector("[data-vocdoni-question-template]");
    this.optionTemplate = root.querySelector("[data-vocdoni-option-template]");
    this.typeSelect = root.querySelector("[data-vocdoni-question-type]");

    this.dirty = false;
    this.saving = false;
    this.blurTimer = null;
    this.intervalTimer = null;
    // Set once the server refuses an autosave outright. Unlike a validation
    // failure, that verdict never changes, so there is nothing to retry.
    this.autosaveRefused = false;
  }

  connect() {
    // A form is the only hard requirement: the question list, the type select
    // and the schedule toggle each belong to one step and are absent on the
    // others.
    if (!this.form) {
      return;
    }

    this.form.addEventListener("click", (event) => this.onClick(event));
    this.form.addEventListener("change", (event) => this.onChange(event));
    this.form.addEventListener("input", () => this.markDirty());
    this.form.addEventListener("submit", () => this.onSubmit());
    this.form.addEventListener("focusout", () => this.scheduleBlurSave());

    window.addEventListener("beforeunload", (event) => this.onBeforeUnload(event));

    this.applyStartImmediately();
    this.applyQuestionType();
    this.renumber();
    this.startAutosaveTimer();
  }

  /* ----------------------------------------------------------------- events */

  onClick(event) {
    const target = event.target;

    const action = (selector) => target.closest(selector);

    if (action("[data-vocdoni-add-question]")) {
      event.preventDefault();
      this.addQuestion();
    } else if (action("[data-vocdoni-remove-question]")) {
      event.preventDefault();
      this.removeQuestion(action("[data-vocdoni-question]"));
    } else if (action("[data-vocdoni-move-question]")) {
      event.preventDefault();
      this.move(action("[data-vocdoni-question]"), action("[data-vocdoni-move-question]").dataset.vocdoniMoveQuestion);
    } else if (action("[data-vocdoni-add-option]")) {
      event.preventDefault();
      this.addOption(action("[data-vocdoni-question]"));
    } else if (action("[data-vocdoni-remove-option]")) {
      event.preventDefault();
      this.removeOption(action("[data-vocdoni-option]"));
    } else if (action("[data-vocdoni-move-option]")) {
      event.preventDefault();
      this.move(action("[data-vocdoni-option]"), action("[data-vocdoni-move-option]").dataset.vocdoniMoveOption);
    }
  }

  onChange(event) {
    this.markDirty();

    if (event.target.matches("[data-vocdoni-question-type]")) {
      this.applyQuestionType();
    } else if (event.target.matches("[data-vocdoni-start-immediately]")) {
      this.applyStartImmediately();
    }
  }

  onSubmit() {
    // A real submit is not an unsaved change.
    this.dirty = false;
    this.cancelTimers();
  }

  onBeforeUnload(event) {
    if (!this.dirty) {
      return;
    }

    event.preventDefault();
    // Browsers ignore the text and show their own, but returnValue is still
    // what triggers the prompt.
    event.returnValue = this.root.dataset.unsavedWarning || "";
  }

  /* -------------------------------------------------------------- questions */

  nextQuestionIndex() {
    const next = parseInt(this.root.dataset.nextQuestionIndex, 10) || 0;
    this.root.dataset.nextQuestionIndex = next + 1;
    return next;
  }

  addQuestion() {
    if (!this.questionTemplate || !this.questionList) {
      return;
    }

    const index = this.nextQuestionIndex();
    const node = parseTemplate(this.questionTemplate.innerHTML.replace(PLACEHOLDER_QUESTION, index));

    this.questionList.appendChild(node);
    this.applyQuestionType();
    this.renumber();
    this.markDirty();
    this.announce(this.root.dataset.announceQuestionAdded);
    node.querySelector("input[type='text']")?.focus();
  }

  removeQuestion(question) {
    if (!question || this.questions().length <= 1) {
      return;
    }

    const next = question.nextElementSibling || question.previousElementSibling;
    question.remove();
    this.renumber();
    this.markDirty();
    this.announce(this.root.dataset.announceQuestionRemoved);
    next?.querySelector("input[type='text']")?.focus();
  }

  questions() {
    if (!this.questionList) {
      return [];
    }

    return Array.from(this.questionList.querySelectorAll("[data-vocdoni-question]"));
  }

  /* ---------------------------------------------------------------- options */

  addOption(question) {
    if (!question || !this.optionTemplate) {
      return;
    }

    const optionIndex = parseInt(question.dataset.nextOptionIndex, 10) || 0;
    question.dataset.nextOptionIndex = optionIndex + 1;

    const html = this.optionTemplate.innerHTML.
      replace(PLACEHOLDER_QUESTION, question.dataset.uid.replace(/^q/, "")).
      replace(PLACEHOLDER_OPTION, optionIndex);
    const node = parseTemplate(html);

    question.querySelector("[data-vocdoni-options]").appendChild(node);
    this.applyQuestionType();
    this.renumber();
    this.markDirty();
    this.announce(this.root.dataset.announceOptionAdded);
    node.querySelector("input[type='text']")?.focus();
  }

  removeOption(option) {
    const list = option?.closest("[data-vocdoni-options]");
    if (!list || list.querySelectorAll("[data-vocdoni-option]").length <= MINIMUM_OPTIONS) {
      return;
    }

    const next = option.nextElementSibling || option.previousElementSibling;
    option.remove();
    this.renumber();
    this.markDirty();
    this.announce(this.root.dataset.announceOptionRemoved);
    next?.querySelector("input[type='text']")?.focus();
  }

  /* --------------------------------------------------------------- ordering */

  move(node, direction) {
    if (!node) {
      return;
    }

    const sibling = direction === "up"
      ? node.previousElementSibling
      : node.nextElementSibling;
    if (!sibling) {
      return;
    }

    if (direction === "up") {
      sibling.before(node);
    } else {
      sibling.after(node);
    }

    this.renumber();
    this.markDirty();
    this.announce(this.root.dataset.announceMoved);

    // The button the admin just pressed moved with the node. Keep the focus on
    // it so a second press keeps going the same way — unless the node has
    // reached the end of the list and the button is now disabled, in which case
    // fall back to the row itself rather than dropping the focus on the body.
    const button = node.querySelector(`[data-vocdoni-move-question='${direction}'], [data-vocdoni-move-option='${direction}']`);
    if (button && !button.disabled) {
      button.focus();
    } else {
      node.querySelector("input[type='text']")?.focus();
    }
  }

  /* ------------------------------------------------------------- numbering */

  /**
   * Rebuilds everything that depends on position: the visible "Question 2 of 3"
   * label, the field set legend a screen reader announces, the option
   * placeholders, the accessible name of every reordering control, and which of
   * those controls still have somewhere to go. A control that cannot do
   * anything is disabled rather than left to fail silently under the admin's
   * finger.
   *
   * The names matter as much as the numbers. "Remove question 2" is a name that
   * has to follow the card it belongs to, or a reorder leaves a screen reader
   * user pressing a control that says one thing and deletes another.
   *
   * @returns {void}
   */
  renumber() {
    const questions = this.questions();
    const total = questions.length;
    const data = this.root.dataset;

    questions.forEach((question, index) => {
      const number = index + 1;

      const label = question.querySelector("[data-vocdoni-question-number]");
      if (label) {
        label.textContent = this.fill(data.questionNumberTemplate, number, total);
      }

      const legend = question.querySelector("[data-vocdoni-question-legend]");
      if (legend) {
        legend.textContent = this.fill(data.questionLegendTemplate, number, total);
      }

      this.control(question.querySelector("[data-vocdoni-move-question='up']"), { enabled: index > 0, template: data.moveQuestionUpTemplate, number });
      this.control(question.querySelector("[data-vocdoni-move-question='down']"), { enabled: index < total - 1, template: data.moveQuestionDownTemplate, number });
      this.control(question.querySelector("[data-vocdoni-remove-question]"), { enabled: total > 1, template: data.removeQuestionTemplate, number });

      const options = Array.from(question.querySelectorAll("[data-vocdoni-option]"));
      options.forEach((option, optionIndex) => {
        const optionNumber = optionIndex + 1;
        const placeholder = this.fill(data.optionPlaceholderTemplate, optionNumber, 0);
        option.querySelectorAll("input[type='text']").forEach((input) => {
          input.placeholder = placeholder;
        });

        const inQuestion = { number: optionNumber, question: number };

        this.control(option.querySelector("[data-vocdoni-move-option='up']"), { enabled: optionIndex > 0, template: data.moveOptionUpTemplate, ...inQuestion });
        this.control(option.querySelector("[data-vocdoni-move-option='down']"), { enabled: optionIndex < options.length - 1, template: data.moveOptionDownTemplate, ...inQuestion });
        this.control(option.querySelector("[data-vocdoni-remove-option]"), { enabled: options.length > MINIMUM_OPTIONS, template: data.removeOptionTemplate, ...inQuestion });
      });
    });
  }

  /**
   * Brings one reordering control up to date: whether it still has anywhere to
   * go, and what it is called now that it has moved.
   *
   * Tolerates a control that is not on the page — the read-only rendering of a
   * ballot that has gone on chain has none of them.
   *
   * @param {HTMLButtonElement|null} button - the control
   * @param {Object} state - what the control is now
   * @param {boolean} state.enabled - whether it has anything left to do
   * @param {string} [state.template] - its accessible name, with `__N__`/`__Q__`
   * @param {number} [state.number] - the position of what the control acts on
   * @param {number} [state.question] - the question that thing belongs to
   * @returns {void}
   */
  control(button, { enabled, template, number, question }) {
    if (!button) {
      return;
    }

    button.disabled = !enabled;
    button.setAttribute("aria-disabled", String(!enabled));

    if (template) {
      button.setAttribute("aria-label", this.fill(template, number, 0).replace(/__Q__/g, question));
    }
  }

  fill(template, number, total) {
    return (template || "").replace(/__N__/g, number).replace(/__T__/g, total);
  }

  /* ------------------------------------------------- process-wide settings */

  applyQuestionType() {
    if (!this.typeSelect) {
      return;
    }

    const multichoice = this.typeSelect.value === "multichoice";

    this.root.querySelectorAll("[data-vocdoni-choice-limits]").forEach((fieldset) => {
      fieldset.hidden = !multichoice;
      // Out of the tab order and out of validation when they do not apply.
      // Upstream ignores `typeSetup` for single-choice questions, and so does
      // the form object, so leaving values behind would only be misleading.
      fieldset.querySelectorAll("input").forEach((input) => {
        input.disabled = !multichoice;
      });
    });

    // The decorative marker in front of every option: a radio for single
    // choice, a box for multiple choice.
    this.root.querySelectorAll("[data-vocdoni-option-marker]").forEach((marker) => {
      marker.classList.toggle("rounded-full", !multichoice);
    });
  }

  applyStartImmediately() {
    const toggle = this.root.querySelector("[data-vocdoni-start-immediately]");
    const wrapper = this.root.querySelector("[data-vocdoni-start-time]");
    if (!toggle || !wrapper) {
      return;
    }

    wrapper.hidden = toggle.checked;
    wrapper.querySelectorAll("input").forEach((input) => {
      input.disabled = toggle.checked;
    });
  }

  /* --------------------------------------------------------------- autosave */

  get autosaveUrl() {
    return this.root.dataset.autosaveUrl || "";
  }

  startAutosaveTimer() {
    const interval = parseInt(this.root.dataset.autosaveInterval, 10);
    if (!this.autosaveUrl || !interval) {
      return;
    }

    this.intervalTimer = window.setInterval(() => this.autosave(), interval);
  }

  scheduleBlurSave() {
    if (!this.autosaveUrl) {
      return;
    }

    window.clearTimeout(this.blurTimer);
    this.blurTimer = window.setTimeout(() => this.autosave(), BLUR_SAVE_DELAY);
  }

  cancelTimers() {
    window.clearTimeout(this.blurTimer);
    window.clearInterval(this.intervalTimer);
  }

  markDirty() {
    this.dirty = true;
  }

  /**
   * The server's reason for refusing an autosave outright, if it gave one.
   *
   * A refusal is distinguished from an ordinary validation failure — both are
   * 422 — by the `refused` flag, because only one of them is worth retrying.
   *
   * @param {Response} response - the failed autosave response
   * @returns {Promise<string|null>} the reason, or null if it is worth retrying
   */
  async refusalReason(response) {
    try {
      const payload = await response.json();

      if (!payload.refused) {
        return null;
      }

      return payload.errors?.[0] || this.root.dataset.announceSaveFailed;
    } catch {
      return null;
    }
  }

  async autosave() {
    if (!this.autosaveUrl || this.autosaveRefused || !this.dirty || this.saving) {
      return;
    }

    this.saving = true;
    this.announce(this.root.dataset.announceSaving);

    try {
      const response = await fetch(this.autosaveUrl, {
        method: "PATCH",
        credentials: "same-origin",
        headers: {
          "X-CSRF-Token": csrfToken(),
          "X-Requested-With": "XMLHttpRequest",
          "Accept": "application/json"
        },
        body: new FormData(this.form)
      });

      if (!response.ok) {
        const refusal = await this.refusalReason(response);

        if (refusal) {
          // The election has gone on chain, or the step is no longer editable.
          // Waiting will not change that, so stop the timers instead of
          // announcing the same failure every thirty seconds, and say what
          // actually happened rather than "could not be saved".
          this.autosaveRefused = true;
          this.cancelTimers();
          this.announce(refusal);
        } else {
          this.announce(this.root.dataset.announceSaveFailed);
        }

        return;
      }

      const payload = await response.json();
      this.applySavedIds(payload.questions || {});
      this.dirty = false;
      this.announce(this.root.dataset.announceSaved);
    } catch {
      // A draft that could not be saved is not an error the admin has to act
      // on: the form is still there, and the next attempt is 30 seconds away.
      this.announce(this.root.dataset.announceSaveFailed);
    } finally {
      this.saving = false;
    }
  }

  /**
   * Writes back the database ids the server has just assigned. Without this a
   * question added in the browser would be created again by every subsequent
   * autosave.
   *
   * @param {Object} questions - map of question uid to `{ id, answers }`
   * @returns {void}
   */
  applySavedIds(questions) {
    if (!this.questionList) {
      return;
    }

    Object.entries(questions).forEach(([uid, data]) => {
      const question = this.questionList.querySelector(`[data-vocdoni-question][data-uid="${uid}"]`);
      if (!question) {
        return;
      }

      const idField = question.querySelector("[data-vocdoni-question-id-field]");
      if (idField && data.id) {
        idField.value = data.id;
      }

      Object.entries(data.answers || {}).forEach(([optionUid, optionId]) => {
        const option = question.querySelector(`[data-vocdoni-option][data-uid="${optionUid}"]`);
        const optionIdField = option?.querySelector("[data-vocdoni-option-id-field]");
        if (optionIdField && optionId) {
          optionIdField.value = optionId;
        }
      });
    });
  }

  /* ------------------------------------------------------------ live region */

  announce(message) {
    if (!this.status || !message) {
      return;
    }

    this.status.textContent = message;
  }
}

const setupElectionEditor = () => {
  document.querySelectorAll("[data-vocdoni-editor]").forEach((root) => {
    new ElectionEditor(root).connect();
  });
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", setupElectionEditor);
} else {
  setupElectionEditor();
}

export { ElectionEditor };
export default setupElectionEditor;
