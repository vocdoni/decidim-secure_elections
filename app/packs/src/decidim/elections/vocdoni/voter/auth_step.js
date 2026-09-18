import { append, clear, el, focusElement, qs, qsa, setDisabled, setText, toggle } from "src/decidim/elections/vocdoni/voter/dom";
import { ErrorCode, toVoteError } from "src/decidim/elections/vocdoni/voter/errors";
import { createTwoFaForm } from "src/decidim/elections/vocdoni/voter/two_fa_form";
import { createOtpStep } from "src/decidim/elections/vocdoni/voter/otp_step";
import { buildCredentialField } from "src/decidim/elections/vocdoni/voter/auth_fields";

/**
 * Census authentication: ARCHITECTURE §3 steps 2 and 3, both the auth-only and the
 * two-factor variants.
 *
 * The credentials the voter types go straight to the Vocdoni CSP and are never
 * sent to Decidim, never written to a URL and never persisted. The resulting
 * auth token lives only inside the flow's closure.
 *
 * Two collaborators do the two-factor work: `two_fa_form.js` collects the
 * channel and the contact — which `authStep0` requires, so they belong on *this*
 * form — and `otp_step.js` runs the code screen. What is left here is the
 * identification form itself and the decision of where the voter goes next.
 *
 * That decision is taken from `census.twoFaFields` alone. It is never taken from
 * `processes.check`, which answers `belongsToProcess: true` for a token that has
 * not been through `authStep1` yet.
 *
 * The form is *built* from the live census rather than rendered by a server, so
 * only the fields this election actually asks for exist at all. The inputs
 * themselves are built by `auth_fields.js`, inside a `<fieldset>` with a
 * `<legend>`.
 */

/**
 * Wires the identification and one-time-code steps.
 *
 * @param {Object} ctx - the voting page context (flow, state, i18n and ui).
 * @returns {Object} `{ bind, applyCensusFields, showClosedNotice }`.
 */
export const createAuthStep = (ctx) => {
  const { flow, state, i18n, ui } = ctx;

  const fieldList = el("div", { class: "vocdoni-field-list" });
  const credentials = el("fieldset", { class: "vocdoni-fieldset" }, [
    el("legend", { class: "vocdoni-visually-hidden", text: i18n.auth.legend }),
    fieldList
  ]);
  const authError = el("p", { id: "js-vocdoni-auth-error", class: "vocdoni-error", role: "alert", hidden: true });
  const authSubmit = el("button", {
    type: "submit",
    id: "js-vocdoni-auth-submit",
    class: "vocdoni-button vocdoni-button--primary",
    text: i18n.auth.submit
  });
  // No `action`: the credential is sent to the Vocdoni CSP by this script and
  // must never round-trip through Decidim, nor end up in a URL.
  const authForm = el("form", { id: "js-vocdoni-auth-form", novalidate: true, autocomplete: "off", class: "vocdoni-form" });
  const twoFa = createTwoFaForm({ authForm, i18n });
  const closedNotice = el("p", { id: "js-vocdoni-auth-closed-notice", class: "vocdoni-notice", text: i18n.closed_notice, hidden: true });

  append(authForm, [
    credentials,
    twoFa.section,
    authError,
    el("div", { class: "vocdoni-nav" }, [ui.exitLink(i18n.cancel), authSubmit])
  ]);

  append(ui.stepNodes.auth, [
    ui.heading(i18n.auth.title),
    el("p", { text: i18n.auth.body }),
    closedNotice,
    authForm,
    // One of the page's quiet reassurances; `vocdoni-note` is the treatment
    // they all share, so they read as a class of statement rather than as
    // unrelated small print.
    el("p", { class: "vocdoni-note", text: i18n.auth.privacy_note })
  ]);

  /**
   * The visible auth inputs, i.e. the fields this census actually asks for.
   *
   * @returns {Element[]} the inputs the voter has to fill in.
   */
  const activeAuthInputs = () => qsa("[data-auth-field-wrapper]", authForm).
    filter((wrapper) => !wrapper.hasAttribute("hidden")).
    map((wrapper) => qs("[data-auth-field]", wrapper)).
    filter(Boolean);

  const collectAuthFields = () => activeAuthInputs().reduce((acc, input) => {
    const value = input.value.trim();

    if (value !== "") {
      acc[input.dataset.authField] = value;
    }

    return acc;
  }, {});

  /**
   * Builds exactly the fields the live census asks for.
   *
   * @param {string[]} fields - the census `authFields`.
   * @param {string[]} twoFaFields - the census `twoFaFields`.
   * @returns {void} nothing.
   */
  const applyCensusFields = (fields, twoFaFields) => {
    const declared = (fields || []).filter((field) => typeof field === "string" && field !== "");

    clear(fieldList);
    append(fieldList, declared.map((field) => buildCredentialField(field, i18n)));
    twoFa.applyCensus(new Set(declared), twoFaFields);
  };

  /**
   * Warns, before anything is typed, that voting does not look open. The
   * authority is still `processes.check`; this only stops the voting page from
   * inviting somebody to vote in an election that has ended, while leaving them
   * able to identify themselves and fetch a receipt.
   *
   * @param {boolean} closed - true when the process is not accepting ballots.
   * @returns {void} nothing.
   */
  const showClosedNotice = (closed) => toggle(closedNotice, closed);

  /**
   * Merges the eligibility answer into the questions and decides where the voter
   * goes next.
   *
   * Only ever reached with a verified token — the flow, not this function, is
   * what guarantees that.
   *
   * @returns {Promise<void>} nothing.
   */
  const afterAuth = async () => {
    ui.announce(i18n.status.checking);

    const result = await flow.check();

    // The check is done. Whatever comes next — a ballot, a receipt or a refusal —
    // renders its own heading, so "Checking what you can vote on…" must not
    // follow the voter into it.
    ui.clearStatus();

    if (!result.belongsToProcess) {
      ui.showBlocked("not_in_census");

      return;
    }

    const byQuestionId = new Map(result.questions.map((item) => [item.questionId, item]));

    state.questions.forEach((question) => {
      const remote = byQuestionId.get(question.vocdoniQuestionId);

      // `check` answers with the ids this voter may sign against; the public
      // process read is only a fallback for a response that omits them.
      question.upstreamId = (remote && remote.upstreamId) || question.processUpstreamId || null;
      question.canVote = Boolean(remote && remote.canVote);
      question.hasVoted = Boolean(remote && remote.hasVoted);
    });

    const votable = state.questions.filter((question) => question.canVote && !question.hasVoted && question.upstreamId);
    const alreadyVoted = state.questions.filter((question) => question.hasVoted);
    const nothingLeftToCast = votable.length === 0 && alreadyVoted.length > 0;

    if (state.intent === "receipt" || nothingLeftToCast) {
      await ctx.receipt.load({ alreadyVoted: nothingLeftToCast });

      return;
    }

    if (votable.length === 0) {
      ui.showBlocked("not_open");

      return;
    }

    ctx.ballot.start(votable.map((question) => state.questions.indexOf(question)));
  };

  /**
   * Abandons a two-factor session and sends the voter back to identification.
   *
   * @param {*} error - the failure that ended the session, or null when the
   *   voter chose to start again.
   * @returns {void} nothing.
   */
  const restartAuth = (error) => {
    flow.reset();
    ui.showInlineError(authError, error
      ? ui.messageForError(error)
      : null);

    if (error) {
      ui.announce(ui.messageForError(error));
    }

    ui.showStep("auth");
  };

  const otp = createOtpStep(ctx, { onVerified: afterAuth, onRestart: restartAuth });

  /**
   * Reports a failure inline when the voter can fix it here, and as a terminal
   * error when they cannot.
   *
   * @param {*} error - the throwable.
   * @returns {void} nothing.
   */
  const reportAuthError = (error) => {
    const voteError = toVoteError(error, ErrorCode.AUTH_REJECTED);
    const retryable = voteError.code === ErrorCode.AUTH_REJECTED ||
      voteError.code === ErrorCode.NETWORK ||
      voteError.code === ErrorCode.AUTH_COOLDOWN;

    if (!retryable) {
      ui.showError(voteError);

      return;
    }

    const message = ui.messageForError(voteError);

    ui.showInlineError(authError, message);
    ui.announce(message);
  };

  /**
   * Everything the voter still has to fill in, or null when the form is ready.
   *
   * @param {string} channel - the selected delivery channel.
   * @returns {Object|null} `{ message, focus }`.
   */
  const missingInput = (channel) => {
    if (twoFa.channelCount() > 1 && !channel) {
      return { message: i18n.auth.channel_required, focus: qs("[data-twofa-channel]", twoFa.choice) };
    }

    const blank = activeAuthInputs().filter((input) => input.value.trim() === "");
    const contactMissing = twoFa.channelCount() > 0 && twoFa.contactValue(channel) === "";

    if (blank.length > 0 || contactMissing) {
      return { message: i18n.auth.required, focus: blank[0] || twoFa.contactInput(channel) };
    }

    return null;
  };

  const handleAuthSubmit = async (event) => {
    event.preventDefault();
    ui.showInlineError(authError, null);

    const channel = twoFa.selectedChannel();
    const missing = missingInput(channel);

    if (missing) {
      ui.showInlineError(authError, missing.message);
      ui.announce(missing.message);
      focusElement(missing.focus);

      return;
    }

    setDisabled(authSubmit, true);
    setText(authSubmit, i18n.status.authenticating);
    ui.announce(i18n.status.authenticating);

    try {
      const result = await flow.authenticate(collectAuthFields(), {
        channel,
        contact: twoFa.contactValue(channel)
      });

      if (result.needsOtp) {
        otp.open(result.channel);
      } else {
        await afterAuth();
      }
    } catch (error) {
      reportAuthError(error);
    } finally {
      setDisabled(authSubmit, false);
      setText(authSubmit, i18n.auth.submit);
    }
  };

  /**
   * Attaches the submit handlers.
   *
   * @returns {void} nothing.
   */
  const bind = () => {
    authForm.addEventListener("submit", handleAuthSubmit);
    twoFa.bind();
    otp.bind();
  };

  return { bind, applyCensusFields, showClosedNotice };
};

export default createAuthStep;
