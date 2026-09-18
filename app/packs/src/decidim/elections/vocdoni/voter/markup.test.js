/* global jest */

import { build, buildBallot, byId, i18n, openOtp, question, visible } from "src/decidim/elections/vocdoni/voter/voting_page_fixture";

/**
 * The voting page's markup used to be rendered by Rails, where a `<fieldset>` was a
 * `<fieldset>` because somebody typed one. It is now built in JavaScript, which
 * is the single biggest accessibility risk in this change: nothing about
 * `document.createElement` stops a control from losing its label, its grouping
 * or its focus order.
 *
 * These tests are the guard. They assert on structure and semantics rather than
 * on wording, so they keep meaning something after a rewrite of the copy.
 */

afterEach(() => {
  jest.useRealTimers();
  document.body.innerHTML = "";
});

describe("the identification form", () => {
  it("labels every credential input and gives it an autofill hint", () => {
    build({ authFields: ["memberNumber", "email"] });

    ["memberNumber", "email"].forEach((field) => {
      const input = document.querySelector(`[data-auth-field="${field}"]`);
      const label = document.querySelector(`label[for="${input.id}"]`);

      expect(input.id).not.toBe("");
      expect(label).not.toBeNull();
      expect(label.textContent).toBe(i18n.fields[field]);
      expect(input.getAttribute("autocomplete")).not.toBeNull();
    });
  });

  it("uses the input type that summons the right keyboard", () => {
    build({ authFields: ["email", "phone", "birthDate", "memberNumber"] });

    expect(document.querySelector("[data-auth-field='email']").type).toBe("email");
    expect(document.querySelector("[data-auth-field='phone']").type).toBe("tel");
    expect(document.querySelector("[data-auth-field='birthDate']").type).toBe("date");
    expect(document.querySelector("[data-auth-field='memberNumber']").type).toBe("text");
  });

  it("groups the credentials in a fieldset with a legend", () => {
    build();

    const fieldset = document.querySelector("[data-auth-field-wrapper]").closest("fieldset");

    expect(fieldset).not.toBeNull();
    expect(fieldset.querySelector("legend").textContent).toBe(i18n.auth.legend);
  });

  it("points every input at the form's error message, so a failure is announced with it", () => {
    build({ twoFaFields: ["email"] });

    expect(document.querySelector("[data-auth-field='memberNumber']").getAttribute("aria-describedby")).
      toBe("js-vocdoni-auth-error");
    expect(byId("js-vocdoni-auth-error").getAttribute("role")).toBe("alert");
  });

  it("offers the channel choice as native radios in their own fieldset", () => {
    build({ twoFaFields: ["email", "phone"] });

    const group = byId("js-vocdoni-auth-channel");

    expect(group.tagName).toBe("FIELDSET");
    expect(group.querySelector("legend").textContent).toBe(i18n.auth.channel_legend);
    expect(group.querySelectorAll("input[type='radio']")).toHaveLength(2);
    // One name, so the browser gives arrow-key navigation and single selection.
    expect(new Set(Array.from(group.querySelectorAll("input")).map((input) => input.name)).size).toBe(1);
  });

  it("builds only the fields the live census asks for", () => {
    build({ authFields: ["memberNumber"] });

    expect(document.querySelectorAll("[data-auth-field]")).toHaveLength(1);
    expect(document.querySelector("[data-auth-field='email']")).toBeNull();
  });
});

describe("the one-time-code screen", () => {
  it("is one labelled, pasteable input and not a split-digit widget", async () => {
    await openOtp();

    const input = byId("js-vocdoni-otp-code");

    expect(document.querySelectorAll("#js-vocdoni-otp-form input")).toHaveLength(1);
    expect(document.querySelector(`label[for="${input.id}"]`).textContent).toBe(i18n.otp.label);
    expect(input.getAttribute("inputmode")).toBe("numeric");
    expect(input.getAttribute("autocomplete")).toBe("one-time-code");
    expect(input.getAttribute("aria-describedby")).toBe("js-vocdoni-otp-hint js-vocdoni-otp-error");
  });

  // The button is dimmed while it counts down, so it has to be genuinely
  // unavailable: styling that says "not now" over a control that still acts
  // teaches voters to ignore the styling everywhere else in the voting page.
  it("makes the resend button as disabled as it looks while it counts down", async () => {
    await openOtp({ fakeTimers: true });

    const resend = byId("js-vocdoni-otp-resend");

    expect(resend.disabled).toBe(true);
    expect(resend.getAttribute("aria-disabled")).toBe("true");
    expect(resend.getAttribute("aria-describedby")).toBe("js-vocdoni-otp-resend-hint");
  });

  it("does not put the countdown in a live region", async () => {
    await openOtp({ fakeTimers: true });

    const hint = byId("js-vocdoni-otp-resend-hint");

    expect(hint.getAttribute("aria-live")).toBeNull();
    expect(hint.getAttribute("role")).toBeNull();
  });
});

describe("the ballot", () => {
  const questions = [
    question(),
    question({
      index: 1,
      vocdoniQuestionId: "q2",
      title: "Which projects should we fund?",
      description: "<p>Read the <em>brief</em> first.</p><p>Then choose.</p>",
      type: "multichoice",
      minChoices: 1,
      maxChoices: 2
    })
  ];

  it("renders each question as a fieldset with a legend", () => {
    buildBallot(questions);

    const fieldsets = document.querySelectorAll("[data-question-index]");

    expect(fieldsets).toHaveLength(2);
    fieldsets.forEach((fieldset, index) => {
      expect(fieldset.tagName).toBe("FIELDSET");
      expect(fieldset.querySelector("legend").textContent).toContain(questions[index].title);
    });
  });

  it("numbers the questions for a screen reader without repeating it on screen", () => {
    buildBallot(questions);

    const number = document.querySelector("[data-question-index='0'] legend .vocdoni-visually-hidden");

    expect(number.textContent.trim()).toBe("Question 1:");
  });

  it("uses radios for one choice and checkboxes for several", () => {
    buildBallot(questions);

    expect(document.querySelectorAll("[data-question-index='0'] input[type='radio']")).toHaveLength(2);
    expect(document.querySelectorAll("[data-question-index='1'] input[type='checkbox']")).toHaveLength(2);
  });

  it("labels every choice and groups a question's inputs under one name", () => {
    buildBallot(questions);

    document.querySelectorAll("[data-question-index='0'] input").forEach((input) => {
      expect(document.querySelector(`label[for="${input.id}"]`)).not.toBeNull();
      expect(input.name).toBe("vocdoni_question_0");
    });
  });

  // A description written in Decidim's editor arrives as markup. The voting page
  // renders its text, and never injects it.
  it("renders a rich-text description as plain paragraphs", () => {
    buildBallot(questions);

    const paragraphs = Array.from(document.querySelectorAll("[data-question-index='1'] > p")).
      map((node) => node.textContent);

    expect(paragraphs).toContain("Read the brief first.");
    expect(paragraphs).toContain("Then choose.");
    expect(document.querySelector("[data-question-index='1'] em")).toBeNull();
  });

  it("carries one hidden, assertive error per question", () => {
    buildBallot(questions);

    const error = document.querySelector("[data-question-index='0'] [data-question-error]");

    expect(error.getAttribute("role")).toBe("alert");
    expect(visible(error)).toBe(false);
  });

  it("shows one question at a time and moves focus to its legend", () => {
    const { step } = buildBallot(questions);

    step.start([0, 1]);

    expect(visible(document.querySelector("[data-question-index='0']"))).toBe(true);
    expect(visible(document.querySelector("[data-question-index='1']"))).toBe(false);
    expect(document.activeElement).toBe(document.querySelector("[data-question-index='0'] legend"));
  });

  it("refuses to advance past an unanswered question, and says why", () => {
    const { step, ui } = buildBallot(questions);

    step.start([0, 1]);
    byId("js-vocdoni-ballot-next").click();

    const error = document.querySelector("[data-question-index='0'] [data-question-error]");

    expect(visible(error)).toBe(true);
    expect(error.textContent).toBe(i18n.validation.required);
    expect(ui.announce).toHaveBeenCalledWith(i18n.validation.required);
    expect(visible(document.querySelector("[data-question-index='1']"))).toBe(false);
  });

  it("records the selection and reaches the review with a per-question edit", () => {
    const { step, ui, state } = buildBallot(questions);

    step.start([0, 1]);
    document.querySelector("#vocdoni-answer-0-1").checked = true;
    byId("js-vocdoni-ballot-next").click();
    document.querySelector("#vocdoni-answer-1-0").checked = true;
    byId("js-vocdoni-ballot-next").click();

    expect(state.questions[0].selected).toEqual([1]);
    expect(ui.showStep).toHaveBeenLastCalledWith("review");

    const items = document.querySelectorAll("#js-vocdoni-review-list li");

    expect(items).toHaveLength(2);
    expect(items[0].querySelector("[data-review-answers]").textContent).toBe("Bob");
    expect(items[0].querySelector("[data-review-edit]").getAttribute("aria-label")).
      toContain(questions[0].title);
  });
});

describe("the shell", () => {
  it("has exactly one focusable heading per step, and one live region", () => {
    build();

    // The live region is static markup in `vote.html`: a region has to exist
    // before it is written to for the update to be announced.
    const status = byId("js-vocdoni-vote-status");

    expect(status.getAttribute("aria-live")).toBe("polite");
    expect(document.querySelectorAll("[aria-live='polite'][role='status']")).toHaveLength(1);

    ["loading", "auth", "otp", "error"].forEach((name) => {
      const headings = document.querySelectorAll(`#js-vocdoni-step-${name} [data-step-heading]`);

      expect(headings.length).toBeGreaterThanOrEqual(1);
      expect(headings[0].getAttribute("tabindex")).toBe("-1");
    });
  });

  it("marks the current stage of the progress trail with aria-current", () => {
    const { ui } = build();

    ui.showStep("ballot");

    const current = document.querySelectorAll("#js-vocdoni-vote-progress [aria-current='step']");

    expect(current).toHaveLength(1);
    expect(current[0].dataset.progressStep).toBe("ballot");
  });

  it("folds the one-time-code screen into the identification stage", () => {
    const { ui } = build({ twoFaFields: ["email"] });

    ui.showStep("otp");

    expect(document.querySelector("[aria-current='step']").dataset.progressStep).toBe("auth");
  });

  // Review is over the moment the ballot is on its way. A trail still pointing
  // at "Review" under a heading that reads "Casting your vote" is describing a
  // screen the voter has already left.
  it("moves the trail on to the final stage while the vote is being cast", () => {
    const { ui } = build();

    ui.showStep("submit");

    const states = Array.from(document.querySelectorAll("[data-progress-step]")).
      map((item) => item.dataset.progressState);

    expect(document.querySelector("[aria-current='step']").dataset.progressStep).toBe("receipt");
    expect(states).toEqual(["done", "done", "done", "current"]);
  });

  it("hides the progress trail on the steps it does not describe", () => {
    const { ui } = build();

    ui.showStep("error");

    expect(visible(byId("js-vocdoni-vote-progress").parentNode)).toBe(false);
  });
});
