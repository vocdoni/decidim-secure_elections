/**
 * The editor has the most to get wrong of anything in the admin: it builds
 * form fields in the browser, and a field whose `name` is off by one index
 * silently sends the wrong ballot. These tests pin the naming, the renumbering
 * and the id write-back that makes autosave idempotent.
 */
import { ElectionEditor } from "src/decidim/secure_elections/admin/election_editor";

const optionMarkup = (questionIndex, optionIndex) => `
  <li class="vocdoni-option" data-vocdoni-option data-uid="q${questionIndex}-a${optionIndex}">
    <input type="hidden" data-vocdoni-option-id-field
           name="election[questions][${questionIndex}][answers][${optionIndex}][id]" value="">
    <input type="hidden"
           name="election[questions][${questionIndex}][answers][${optionIndex}][uid]"
           value="q${questionIndex}-a${optionIndex}">
    <span data-vocdoni-option-marker class="rounded-full"></span>
    <input type="text" name="election[questions][${questionIndex}][answers][${optionIndex}][title_en]">
    <button type="button" data-vocdoni-move-option="up"></button>
    <button type="button" data-vocdoni-move-option="down"></button>
    <button type="button" data-vocdoni-remove-option></button>
  </li>
`;

const questionMarkup = (index, optionCount = 2) => `
  <li class="vocdoni-question" data-vocdoni-question data-uid="q${index}" data-next-option-index="${optionCount}">
    <fieldset>
      <legend data-vocdoni-question-legend></legend>
      <input type="hidden" data-vocdoni-question-id-field name="election[questions][${index}][id]" value="">
      <input type="hidden" name="election[questions][${index}][uid]" value="q${index}">
      <p data-vocdoni-question-number></p>
      <button type="button" data-vocdoni-move-question="up"></button>
      <button type="button" data-vocdoni-move-question="down"></button>
      <button type="button" data-vocdoni-remove-question></button>
      <input type="text" name="election[questions][${index}][title_en]">
      <fieldset data-vocdoni-choice-limits hidden>
        <input type="number" name="election[questions][${index}][min_choices]">
        <input type="number" name="election[questions][${index}][max_choices]">
      </fieldset>
      <ul data-vocdoni-options>
        ${Array.from({ length: optionCount }, (_unused, optionIndex) => optionMarkup(index, optionIndex)).join("")}
      </ul>
      <button type="button" data-vocdoni-add-option></button>
    </fieldset>
  </li>
`;

const render = ({ questionCount = 1, autosaveUrl = "" } = {}) => {
  document.body.innerHTML = `
    <form id="editor-form">
      <div data-vocdoni-editor
           data-next-question-index="${questionCount}"
           data-autosave-url="${autosaveUrl}"
           data-autosave-interval="0"
           data-question-number-template="Question __N__ of __T__"
           data-question-legend-template="Question __N__"
           data-option-placeholder-template="Option __N__"
           data-move-question-up-template="Move question __N__ up"
           data-move-question-down-template="Move question __N__ down"
           data-remove-question-template="Remove question __N__"
           data-move-option-up-template="Move option __N__ of question __Q__ up"
           data-move-option-down-template="Move option __N__ of question __Q__ down"
           data-remove-option-template="Remove option __N__ of question __Q__"
           data-announce-question-added="Question added."
           data-announce-option-added="Option added."
           data-announce-moved="Order changed.">
        <p data-vocdoni-status></p>
        <select data-vocdoni-question-type>
          <option value="singlechoice" selected>Single</option>
          <option value="multichoice">Multiple</option>
        </select>
        <ul data-vocdoni-questions>
          ${Array.from({ length: questionCount }, (_unused, index) => questionMarkup(index)).join("")}
        </ul>
        <button type="button" data-vocdoni-add-question></button>
        <template data-vocdoni-question-template>${questionMarkup("__QIDX__")}</template>
        <template data-vocdoni-option-template>${optionMarkup("__QIDX__", "__AIDX__")}</template>
      </div>
    </form>
  `;

  const root = document.querySelector("[data-vocdoni-editor]");
  const editor = new ElectionEditor(root);
  editor.connect();

  return { root, editor };
};

const names = () => Array.from(document.querySelectorAll("input")).map((input) => input.name);

describe("ElectionEditor", () => {
  describe("adding a question", () => {
    it("names its fields with a fresh index so nothing overwrites anything", () => {
      render();

      document.querySelector("[data-vocdoni-add-question]").click();

      expect(document.querySelectorAll("[data-vocdoni-question]")).toHaveLength(2);
      expect(names()).toContain("election[questions][1][title_en]");
      expect(names()).toContain("election[questions][1][answers][0][title_en]");
      // The placeholder must not survive anywhere.
      expect(names().join(" ")).not.toContain("__QIDX__");
    });

    it("gives it two options, because one option is not a choice", () => {
      render();

      document.querySelector("[data-vocdoni-add-question]").click();
      const added = document.querySelectorAll("[data-vocdoni-question]")[1];

      expect(added.querySelectorAll("[data-vocdoni-option]")).toHaveLength(2);
    });

    it("renumbers the visible and the announced labels", () => {
      render();

      document.querySelector("[data-vocdoni-add-question]").click();

      const labels = Array.from(document.querySelectorAll("[data-vocdoni-question-number]"));
      expect(labels.map((label) => label.textContent)).toEqual(["Question 1 of 2", "Question 2 of 2"]);
    });

    it("announces itself, since nothing else tells a screen reader", () => {
      const { root } = render();

      document.querySelector("[data-vocdoni-add-question]").click();

      expect(root.querySelector("[data-vocdoni-status]").textContent).toEqual("Question added.");
    });
  });

  describe("adding an option", () => {
    it("only has to be unique within its question, not contiguous overall", () => {
      render();

      document.querySelector("[data-vocdoni-add-option]").click();

      expect(names()).toContain("election[questions][0][answers][2][title_en]");
      expect(document.querySelectorAll("[data-vocdoni-option]")).toHaveLength(3);
    });

    it("numbers the placeholders in reading order", () => {
      render();

      document.querySelector("[data-vocdoni-add-option]").click();

      const placeholders = Array.from(document.querySelectorAll("[data-vocdoni-option] input[type='text']"));
      expect(placeholders.map((input) => input.placeholder)).toEqual(["Option 1", "Option 2", "Option 3"]);
    });
  });

  describe("removing", () => {
    it("refuses to leave a question with fewer than two options", () => {
      render();

      document.querySelectorAll("[data-vocdoni-remove-option]")[0].click();

      expect(document.querySelectorAll("[data-vocdoni-option]")).toHaveLength(2);
    });

    it("disables the controls that have nothing left to do", () => {
      render();

      expect(document.querySelector("[data-vocdoni-remove-question]").disabled).toBe(true);
      expect(document.querySelectorAll("[data-vocdoni-remove-option]")[0].disabled).toBe(true);
      expect(document.querySelector("[data-vocdoni-move-question='up']").disabled).toBe(true);
    });

    it("removes a question once there is more than one", () => {
      render({ questionCount: 2 });

      document.querySelectorAll("[data-vocdoni-remove-question]")[0].click();

      expect(document.querySelectorAll("[data-vocdoni-question]")).toHaveLength(1);
    });
  });

  describe("reordering", () => {
    it("moves the node and renumbers, leaving the field names alone", () => {
      render({ questionCount: 2 });

      const before = Array.from(document.querySelectorAll("[data-vocdoni-question]")).map((node) => node.dataset.uid);
      document.querySelectorAll("[data-vocdoni-move-question='down']")[0].click();
      const after = Array.from(document.querySelectorAll("[data-vocdoni-question]")).map((node) => node.dataset.uid);

      expect(before).toEqual(["q0", "q1"]);
      expect(after).toEqual(["q1", "q0"]);
      // Position is derived from DOM order on save, so the indices in the names
      // are meaningless and must not be rewritten.
      expect(names()).toContain("election[questions][0][title_en]");
      expect(names()).toContain("election[questions][1][title_en]");
    });
  });

  // Without a name of its own every one of these reaches a screen reader as a
  // bare "button" — beside a control that deletes a question.
  describe("the accessible names of the reordering controls", () => {
    const label = (node, selector) => node.querySelector(selector).getAttribute("aria-label");

    it("names every control after the thing it acts on", () => {
      render({ questionCount: 2 });
      const question = document.querySelectorAll("[data-vocdoni-question]")[1];
      const option = question.querySelectorAll("[data-vocdoni-option]")[1];

      expect(label(question, "[data-vocdoni-move-question='up']")).toEqual("Move question 2 up");
      expect(label(question, "[data-vocdoni-remove-question]")).toEqual("Remove question 2");
      expect(label(option, "[data-vocdoni-move-option='down']")).toEqual("Move option 2 of question 2 down");
      expect(label(option, "[data-vocdoni-remove-option]")).toEqual("Remove option 2 of question 2");
    });

    it("follows the card when it moves, so a control never names another question", () => {
      render({ questionCount: 2 });
      const first = document.querySelectorAll("[data-vocdoni-question]")[0];

      document.querySelectorAll("[data-vocdoni-move-question='down']")[0].click();

      expect(label(first, "[data-vocdoni-remove-question]")).toEqual("Remove question 2");
      expect(label(first, "[data-vocdoni-remove-option]")).toEqual("Remove option 1 of question 2");
    });

    it("names a question added in the browser, which the template cannot", () => {
      render();

      document.querySelector("[data-vocdoni-add-question]").click();

      expect(label(document.querySelectorAll("[data-vocdoni-question]")[1], "[data-vocdoni-remove-question]")).
        toEqual("Remove question 2");
    });
  });

  describe("the process-wide question type", () => {
    it("reveals the selection limits only where they apply", () => {
      const { root } = render();
      const limits = root.querySelector("[data-vocdoni-choice-limits]");
      const select = root.querySelector("[data-vocdoni-question-type]");

      expect(limits.hidden).toBe(true);

      select.value = "multichoice";
      select.dispatchEvent(new Event("change", { bubbles: true }));

      expect(limits.hidden).toBe(false);
      expect(limits.querySelector("input").disabled).toBe(false);
    });
  });

  describe("autosave", () => {
    it("writes the returned ids back so the next save updates instead of duplicating", () => {
      const { editor } = render({ autosaveUrl: "/autosave" });

      editor.applySavedIds({
        q0: { id: 42, answers: { "q0-a0": 7, "q0-a1": 8 } }
      });

      const question = document.querySelector("[data-vocdoni-question][data-uid='q0']");
      expect(question.querySelector("[data-vocdoni-question-id-field]").value).toEqual("42");
      expect(
        question.querySelector("[data-vocdoni-option][data-uid='q0-a0'] [data-vocdoni-option-id-field]").value
      ).toEqual("7");
    });

    it("ignores ids for rows that are no longer on the page", () => {
      const { editor } = render({ autosaveUrl: "/autosave" });

      expect(() => editor.applySavedIds({ q9: { id: 1, answers: {} } })).not.toThrow();
    });
  });
});
