import { append, clear, el, focusElement, interpolate, qsa, setText, toggle } from "src/decidim/elections/vocdoni/voter/dom";
import { ErrorCode, toVoteError } from "src/decidim/elections/vocdoni/voter/errors";
import { createProgress } from "src/decidim/elections/vocdoni/voter/progress";

/**
 * The voting page's shell: the step machine and the surfaces every step shares.
 *
 * The voting page used to be a server-rendered document whose steps were shown and
 * hidden. It is now a static page, so the sections are built here instead — but
 * they are still built *once*, at startup, and then shown and hidden. Nothing
 * re-creates a step on transition, which is what keeps every `<fieldset>`, every
 * label association and every focus target stable for the whole flow.
 *
 * Two things are static markup in `vote.html` rather than built here, on
 * purpose:
 *
 *   * the `aria-live` status region, because a live region has to be in the
 *     document *before* it is written to for an update to be announced;
 *   * the "the voting page could not start" message, because it has to work even when
 *     no translation file could be fetched.
 */

export const STEPS = ["loading", "auth", "otp", "ballot", "review", "submit", "receipt", "blocked", "error"];

/** The reasons the voting page can honestly refuse to open a ballot. */
const BLOCKED_REASONS = ["not_in_census", "already_voted", "not_open"];

/**
 * Builds the step machine and paints the shell into `root`.
 *
 * @param {Object} options - configuration.
 * @param {Element} options.root - the voting page container.
 * @param {Object} options.i18n - the loaded translations.
 * @param {string} [options.exitUrl] - where "leave the voting page" goes, when the
 *   link that opened the voting page said so.
 * @param {Element} [options.statusNode] - the shared live region.
 * @returns {Object} the UI surface used by every step module.
 */
export const createUi = ({ root, i18n, exitUrl = null, statusNode = null }) => {
  const stepNodes = {};
  const progress = createProgress({ i18n });
  const errorMessage = el("p", { id: "js-vocdoni-error-message", role: "alert" });
  const retryButton = el("button", {
    type: "button",
    id: "js-vocdoni-error-retry",
    class: "vocdoni-button vocdoni-button--primary",
    text: i18n.error.retry
  });

  /**
   * The "leave the voting page" link, or nothing when the voting page was opened without an
   * exit. A dead link is worse than no link.
   *
   * @param {string} label - the link text.
   * @returns {Element|null} the anchor.
   */
  const exitLink = (label) => (exitUrl
    ? el("a", { href: exitUrl, class: "vocdoni-button vocdoni-button--quiet", text: label })
    : null);

  /**
   * A step heading. `data-step-heading` is what {@link showStep} focuses, and
   * `tabindex="-1"` is what makes it focusable without putting it in the tab
   * order.
   *
   * `h2`, not `h1`: the page's one `h1` is the election title in the banner, and
   * a step is a section of it. That keeps a single, honest document outline
   * however many steps have been built.
   *
   * @param {string} text - the heading.
   * @param {Object} [options] - rendering options.
   * @param {boolean} [options.visuallyHidden] - true for a step whose heading is
   *   structural rather than decorative, so it names the step for assistive
   *   technology without repeating itself on screen.
   * @returns {Element} the heading.
   */
  const heading = (text, { visuallyHidden = false } = {}) => el("h2", {
    class: visuallyHidden
      ? "vocdoni-visually-hidden"
      : "vocdoni-step__title",
    "data-step-heading": true,
    tabindex: "-1",
    text
  });

  /**
   * Publishes a message in the single polite live region, so status changes are
   * announced without stealing focus.
   *
   * @param {string} message - the message to announce.
   * @returns {void} nothing.
   */
  const announce = (message) => setText(statusNode, message);

  /**
   * Empties the live region.
   *
   * A status line describes what the voting page is *doing*. Once a step has finished
   * rendering there is nothing in flight, so leaving the last message up turns
   * the region into a lie — "Loading the election…" above a fully drawn
   * identification form, "Checking what you can vote on…" above a ballot that is
   * already open. Every step clears it when it lands; the ones that are genuinely
   * still working (casting) keep writing to it instead.
   *
   * @returns {void} nothing.
   */
  const clearStatus = () => announce("");

  /**
   * Turns any throwable into the voter-facing message for its class of failure.
   *
   * Some of those messages take a value — a cooldown says how many seconds are
   * left — which the error carries in `details`. Nothing secret ever goes in
   * there; see `VoteError`.
   *
   * @param {*} error - any throwable.
   * @returns {string} the translated message.
   */
  const messageForError = (error) => {
    const voteError = toVoteError(error);
    const messages = i18n.errors || {};
    const message = messages[voteError.code] || messages[ErrorCode.UNKNOWN] || voteError.code;

    return interpolate(message, voteError.details);
  };

  /**
   * Shows or clears an inline, `role="alert"` message next to a control.
   *
   * @param {Element} node - the message element.
   * @param {string} message - the message, or null to clear it.
   * @returns {void} nothing.
   */
  const showInlineError = (node, message) => {
    setText(node, message);
    toggle(node, Boolean(message));
  };

  /**
   * Makes one step the only visible one and moves focus to its heading.
   *
   * Nothing is written to the address bar here, ever: the ballot must not end up
   * in a URL, and a back button that replayed a half-cast vote would be worse
   * than no history at all.
   *
   * @param {string} step - one of {@link STEPS}.
   * @returns {void} nothing.
   */
  const showStep = (step) => {
    STEPS.forEach((name) => toggle(stepNodes[name], name === step));
    progress.update(step);

    // The blocked step holds one heading per reason; focus the one that is
    // actually on screen rather than the first in document order.
    const target = stepNodes[step] &&
      qsa("[data-step-heading]", stepNodes[step]).find((node) => !node.closest("[hidden]"));

    focusElement(target);
  };

  /**
   * Renders the terminal error state.
   *
   * @param {*} error - any throwable.
   * @returns {void} nothing.
   */
  const showError = (error) => {
    setText(errorMessage, messageForError(error));
    // The error is its own `role="alert"`; whatever the status line was saying
    // ("Loading the election…") is over.
    clearStatus();
    showStep("error");
  };

  /**
   * Renders one of the "you cannot vote right now" states. These are answers,
   * not failures: `belongsToProcess: false` arrives with HTTP 200
   * (ARCHITECTURE §3), and a closed election is simply a state.
   *
   * @param {string} reason - `not_in_census`, `already_voted` or `not_open`.
   * @returns {void} nothing.
   */
  const showBlocked = (reason) => {
    qsa("[data-blocked-reason]", stepNodes.blocked).forEach((node) => {
      toggle(node, node.dataset.blockedReason === reason);
    });
    // A terminal state carries its own heading, which `showStep` focuses.
    clearStatus();
    showStep("blocked");
  };

  /**
   * Builds the shell: the progress trail, one section per step, and the steps
   * whose content never depends on the election.
   *
   * @returns {void} nothing.
   */
  const mount = () => {
    clear(root);
    progress.build();
    root.appendChild(progress.nav);

    STEPS.forEach((name) => {
      stepNodes[name] = el("section", {
        id: `js-vocdoni-step-${name}`,
        class: "vocdoni-step",
        hidden: name !== "loading"
      });
      root.appendChild(stepNodes[name]);
    });

    append(stepNodes.loading, [
      heading(i18n.loading.title),
      el("p", { text: i18n.loading.body })
    ]);

    append(stepNodes.blocked, [
      BLOCKED_REASONS.map((reason) => el("div", { dataset: { blockedReason: reason }, hidden: true }, [
        heading(i18n.blocked[reason].title),
        el("p", { text: i18n.blocked[reason].body })
      ])),
      el("div", { class: "vocdoni-nav" }, exitLink(i18n.blocked.back))
    ]);

    append(stepNodes.error, [
      heading(i18n.error.title),
      errorMessage,
      el("div", { class: "vocdoni-nav" }, [exitLink(i18n.cancel), retryButton])
    ]);
  };

  /**
   * Wires the retry button of the terminal error state.
   *
   * @param {Function} handler - what to run when the voter retries.
   * @returns {void} nothing.
   */
  const onRetry = (handler) => retryButton.addEventListener("click", handler);

  return {
    mount,
    onRetry,
    exitLink,
    heading,
    stepNodes,
    announce,
    clearStatus,
    messageForError,
    showInlineError,
    showStep,
    showError,
    showBlocked
  };
};

export default createUi;
