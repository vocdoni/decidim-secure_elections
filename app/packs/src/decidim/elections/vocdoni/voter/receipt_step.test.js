/* global jest */

import { buildReceipt, byId, i18n, question, visible } from "src/decidim/elections/vocdoni/voter/voting_page_fixture";

/**
 * The receipt is the last thing a voter sees, and the only page that has to
 * survive being read once and closed. These tests hold it to that: it says the
 * vote was recorded, it hands the code over without a manual selection, and it
 * says the code can be found again — while still refusing to claim a vote that
 * is not there.
 */

const NULLIFIER = "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";

/** Restores whatever the clipboard stubs replaced. */
const originals = { clipboard: null, secure: null };

/**
 * Stubs the clipboard and the secure-context flag, neither of which jsdom
 * provides and neither of which is writable by plain assignment.
 *
 * @param {Object} options - what to pretend.
 * @param {Object|null} options.clipboard - the clipboard, or null for none.
 * @param {boolean} options.secure - whether the page is in a secure context.
 * @returns {void} nothing.
 */
const stubClipboard = ({ clipboard, secure }) => {
  originals.clipboard = Reflect.getOwnPropertyDescriptor(window.navigator, "clipboard") || null;
  originals.secure = Reflect.getOwnPropertyDescriptor(window, "isSecureContext") || null;

  Reflect.defineProperty(window.navigator, "clipboard", { value: clipboard, configurable: true });
  Reflect.defineProperty(window, "isSecureContext", { value: secure, configurable: true });
};

afterEach(() => {
  if (originals.clipboard) {
    Reflect.defineProperty(window.navigator, "clipboard", originals.clipboard);
  } else {
    Reflect.deleteProperty(window.navigator, "clipboard");
  }

  if (originals.secure) {
    Reflect.defineProperty(window, "isSecureContext", originals.secure);
  }

  originals.clipboard = null;
  originals.secure = null;
  jest.clearAllMocks();
  document.body.innerHTML = "";
});

/**
 * A question this voter has a receipt for.
 *
 * @returns {Object} the question.
 */
const voted = () => question({ nullifier: NULLIFIER, hasVoted: true });

describe("the receipt", () => {
  it("leads with an affirmative heading and a decorative success mark", async () => {
    const { step } = buildReceipt({ questions: [voted()] });

    await step.load();

    const outcome = document.querySelector("[data-receipt-recorded]");

    expect(visible(outcome)).toBe(true);
    expect(outcome.querySelector("[data-step-heading]").textContent).toBe(i18n.receipt.recorded_title);
    // Decoration, not information: the heading already carries the meaning.
    expect(outcome.querySelector(".vocdoni-receipt__seal").getAttribute("aria-hidden")).toBe("true");
  });

  it("keeps exactly one focusable heading, and focuses it", async () => {
    const { step } = buildReceipt({ questions: [voted()] });

    await step.load();

    const headings = Array.from(document.querySelectorAll("#js-vocdoni-step-receipt [data-step-heading]")).
      filter((node) => !node.closest("[hidden]"));

    expect(headings).toHaveLength(1);
    expect(document.activeElement).toBe(headings[0]);
  });

  it("will not claim a vote it cannot find", async () => {
    const { step } = buildReceipt({ questions: [question()] });

    await step.load();

    expect(visible(document.querySelector("[data-receipt-recorded]"))).toBe(false);
    expect(visible(byId("js-vocdoni-receipt-empty"))).toBe(true);
    expect(document.activeElement.textContent).toBe(i18n.receipt.title);
  });

  it("says the receipts can be found again, but only when there are some", async () => {
    const { step } = buildReceipt({ questions: [voted()] });

    await step.load();
    expect(visible(byId("js-vocdoni-receipt-return"))).toBe(true);
    expect(byId("js-vocdoni-receipt-return").textContent).toBe(i18n.receipt.return_note);

    const empty = buildReceipt({ questions: [question()] });

    await empty.step.load();
    expect(visible(byId("js-vocdoni-receipt-return"))).toBe(false);
  });

  it("takes the nullifier from the CSP when this session did not cast the vote", async () => {
    const { step } = buildReceipt({
      questions: [question()],
      consumed: [{ questionId: "q1", nullifier: NULLIFIER }]
    });

    await step.load();

    expect(document.querySelector("[data-receipt-nullifier]").textContent).toBe(NULLIFIER);
  });

  it("clears the status line rather than leaving the last thing it said", async () => {
    const { step } = buildReceipt({ questions: [voted()] });

    byId("js-vocdoni-vote-status").textContent = i18n.status.done;
    await step.load();

    expect(byId("js-vocdoni-vote-status").textContent).toBe("");
  });
});

describe("copying a receipt code", () => {
  it("names the question, so several receipts are told apart", async () => {
    const { step } = buildReceipt({ questions: [voted()] });

    await step.load();

    const button = document.querySelector("[data-receipt-copy]");

    // The visible word starts the accessible name, so speech control still works.
    expect(button.textContent).toBe(i18n.receipt.copy);
    expect(button.getAttribute("aria-label")).toContain(i18n.receipt.copy);
    expect(button.getAttribute("aria-label")).toContain("Who should chair the board?");
  });

  it("puts the whole nullifier on the clipboard in a secure context", async () => {
    const writeText = jest.fn().mockResolvedValue();

    stubClipboard({ clipboard: { writeText }, secure: true });

    const { step, ui } = buildReceipt({ questions: [voted()] });

    await step.load();
    document.querySelector("[data-receipt-copy]").click();
    await Promise.resolve();
    await Promise.resolve();

    expect(writeText).toHaveBeenCalledWith(NULLIFIER);
    expect(document.querySelector("[data-receipt-copy-feedback]").textContent).toBe(i18n.receipt.copied);
    expect(ui.announce).toHaveBeenCalledWith(i18n.receipt.copied);
  });

  // The clipboard API needs a secure context and plenty of installations are
  // reached over plain HTTP, so the fallback is the path that has to work.
  it("selects the code and asks for a manual copy when there is no clipboard", async () => {
    stubClipboard({ clipboard: null, secure: false });

    const { step, ui } = buildReceipt({ questions: [voted()] });

    await step.load();
    document.querySelector("[data-receipt-copy]").click();
    await Promise.resolve();
    await Promise.resolve();

    expect(document.querySelector("[data-receipt-copy-feedback]").textContent).toBe(i18n.receipt.copy_manual);
    expect(ui.announce).toHaveBeenCalledWith(i18n.receipt.copy_manual);
    expect(window.getSelection().toString()).toBe(NULLIFIER);
  });

  it("falls back to the selection when the clipboard write is refused", async () => {
    stubClipboard({ clipboard: { writeText: jest.fn().mockRejectedValue(new Error("denied")) }, secure: true });

    const { step } = buildReceipt({ questions: [voted()] });

    await step.load();
    document.querySelector("[data-receipt-copy]").click();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    expect(document.querySelector("[data-receipt-copy-feedback]").textContent).toBe(i18n.receipt.copy_manual);
  });
});
