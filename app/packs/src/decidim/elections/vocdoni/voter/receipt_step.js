import { append, clear, el, interpolate, setText, toggle } from "src/decidim/elections/vocdoni/voter/dom";

/**
 * The receipt.
 *
 * A receipt is a nullifier: proof that a vote was recorded, revealing nothing
 * about its content. Nullifiers are fetched back from the CSP (`signInfo`)
 * rather than carried around by the voting page, which is what lets the receipt be
 * reachable after re-authenticating — ARCHITECTURE §0 forbids stashing anything in
 * a URL, in storage or in a session.
 *
 * This is the last thing a voter sees, so it has to *close the loop*: an
 * affirmative heading rather than a filing label, a mark that reads as success
 * at a glance, and a plain sentence saying the receipt is not the only copy —
 * coming back and identifying again brings it up. Without that last line a voter
 * has every reason to believe this screen is the one chance to keep the code,
 * which is exactly the pressure that produces screenshots of a voting session.
 *
 * The heading is conditional, because this step is also where a voter who has
 * *not* voted lands when they come looking for a receipt. "Your vote was
 * recorded" over an empty list would be a lie, so the neutral title stays for
 * that case.
 *
 * There is deliberately no "view on the explorer" link. The voting page knows only
 * the API base URL and the process id (its whole query string), so it cannot
 * know which explorer this deployment belongs to, and a link built from a guess
 * would either 404 or — worse — send a voter to somebody else's explorer to
 * "verify" their vote. The nullifier is shown in full instead, selectable, in a
 * monospace face and with a copy button, so it can be pasted into whichever
 * explorer the organisers actually name.
 */

/**
 * Selects an element's text, so a voter can copy it by hand.
 *
 * This is the fallback that matters: `navigator.clipboard` needs a secure
 * context and plenty of Decidim installations are reached over plain HTTP on a
 * LAN. `admin/public_link.js` does the same thing for the organiser's link.
 *
 * @param {Element} node - the element whose text should be selected.
 * @returns {void} nothing.
 */
const selectText = (node) => {
  const selection = typeof window.getSelection === "function"
    ? window.getSelection()
    : null;

  if (!selection || typeof document.createRange !== "function") {
    return;
  }

  const range = document.createRange();

  range.selectNodeContents(node);
  selection.removeAllRanges();
  selection.addRange(range);
};

/**
 * Wires the receipt step.
 *
 * @param {Object} ctx - the voting page context (flow, state, i18n and ui).
 * @returns {Object} `{ load }`.
 */
export const createReceiptStep = (ctx) => {
  const { flow, state, i18n, ui } = ctx;

  // Decorative and `aria-hidden`: the heading next to it already says the vote
  // was recorded, and a tick that were also announced would say it twice.
  const seal = el("p", { class: "vocdoni-receipt__seal", "aria-hidden": "true", text: "✓" });
  const recordedHeading = ui.heading(i18n.receipt.recorded_title);
  const recorded = el("div", { class: "vocdoni-receipt__outcome", "data-receipt-recorded": true, hidden: true }, [
    seal,
    recordedHeading
  ]);
  const neutralHeading = ui.heading(i18n.receipt.title);
  const intro = el("p", { text: i18n.receipt.body });
  const list = el("ul", { id: "js-vocdoni-receipt-list", class: "vocdoni-receipt" });
  const emptyNotice = el("p", { id: "js-vocdoni-receipt-empty", text: i18n.receipt.empty, hidden: true });
  const returnNote = el("p", {
    id: "js-vocdoni-receipt-return",
    // The same quiet treatment as the identification step's privacy note: both
    // are reassurances rather than instructions.
    class: "vocdoni-note",
    text: i18n.receipt.return_note,
    hidden: true
  });
  const alreadyVotedNotice = el("p", {
    id: "js-vocdoni-receipt-already-voted",
    class: "vocdoni-notice",
    text: i18n.receipt.already_voted,
    hidden: true
  });

  append(ui.stepNodes.receipt, [
    recorded,
    neutralHeading,
    intro,
    alreadyVotedNotice,
    list,
    emptyNotice,
    returnNote,
    el("div", { class: "vocdoni-nav" }, ui.exitLink(i18n.receipt.exit))
  ]);

  const fetchConsumed = async () => {
    // A receipt lookup failure must not hide a successful vote: fall back to
    // whatever nullifiers this session already produced.
    try {
      return await flow.receipts();
    } catch {
      return [];
    }
  };

  /**
   * Puts one nullifier on the clipboard, or in the selection when there is no
   * clipboard to put it on.
   *
   * @param {Element} code - the element holding the nullifier.
   * @param {Element} feedback - where to say what happened.
   * @returns {Promise<void>} nothing.
   */
  const copyNullifier = async (code, feedback) => {
    // Select first, unconditionally: it is what makes the manual fallback work,
    // and it shows the voter exactly which characters are being copied.
    selectText(code);

    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(code.textContent);
        setText(feedback, i18n.receipt.copied);
        ui.announce(i18n.receipt.copied);

        return;
      }
    } catch {
      // Fall through to the selection fallback below.
    }

    // The text is selected either way, so the worst case is the voter's own
    // copy gesture. The message deliberately names none of them: this voting page is
    // used on phones as much as on desktops, and "press Ctrl+C" is meaningless
    // on a touchscreen and wrong on a Mac. "Selected, ready to copy" is true
    // wherever it is read.
    setText(feedback, i18n.receipt.copy_manual);
    ui.announce(i18n.receipt.copy_manual);
  };

  /**
   * Builds one receipt.
   *
   * @param {Object} question - the question that was voted on.
   * @param {string} nullifier - the receipt code.
   * @returns {Element} the list item.
   */
  const buildReceipt = (question, nullifier) => {
    const code = el("code", { class: "vocdoni-receipt__nullifier", "data-receipt-nullifier": true, text: nullifier });
    const feedback = el("span", { class: "vocdoni-hint", "data-receipt-copy-feedback": true });
    // The visible label is short, but every receipt on the page would carry the
    // same one; the accessible name names the question, and still starts with
    // the visible word so speech control keeps working.
    const copy = el("button", {
      type: "button",
      class: "vocdoni-button vocdoni-button--quiet vocdoni-button--small",
      "data-receipt-copy": true,
      "aria-label": interpolate(i18n.receipt.copy_label, { question: question.title }),
      text: i18n.receipt.copy
    });

    copy.addEventListener("click", () => copyNullifier(code, feedback));

    return el("li", { class: "vocdoni-receipt__item" }, [
      el("p", { class: "vocdoni-receipt__question", "data-receipt-question": true, text: question.title }),
      el("p", { class: "vocdoni-hint", text: i18n.receipt.nullifier_label }),
      code,
      el("div", { class: "vocdoni-receipt__actions" }, [copy, feedback])
    ]);
  };

  /**
   * Renders every receipt this voter has, from the CSP and from this session.
   *
   * @param {Object} [options] - rendering options.
   * @param {boolean} [options.alreadyVoted] - true when the voter came to cast a
   *   ballot but had nothing left to cast.
   * @returns {Promise<void>} nothing.
   */
  const load = async (options = {}) => {
    const consumed = await fetchConsumed();
    const byQuestionId = new Map(consumed.map((item) => [item.questionId, item]));

    clear(list);

    const rendered = state.questions.filter((question) => {
      const remote = byQuestionId.get(question.vocdoniQuestionId);
      const nullifier = question.nullifier || (remote && remote.nullifier);

      if (!nullifier) {
        return false;
      }

      list.appendChild(buildReceipt(question, nullifier));

      return true;
    }).length;

    // Nothing left to cast *and* no receipt to show: say plainly that the vote
    // is already in, rather than presenting an empty receipt page.
    if (rendered === 0 && options.alreadyVoted) {
      ui.showBlocked("already_voted");

      return;
    }

    const hasReceipts = rendered > 0;

    // Exactly one of the two headings is on screen, so the step keeps a single
    // focus target and a single honest document outline.
    toggle(recorded, hasReceipts);
    toggle(neutralHeading, !hasReceipts);
    toggle(intro, hasReceipts);
    toggle(returnNote, hasReceipts);
    toggle(emptyNotice, !hasReceipts);
    toggle(alreadyVotedNotice, Boolean(options.alreadyVoted) && hasReceipts);
    // Nothing is in flight any more, and the heading `showStep` focuses says
    // what happened far better than "Done." did.
    ui.clearStatus();
    ui.showStep("receipt");
  };

  return { load };
};

export default createReceiptStep;
