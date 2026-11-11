import { createVoterFlow } from "src/decidim/elections/vocdoni/voter/flow";
import { ErrorCode } from "src/decidim/elections/vocdoni/voter/errors";

/**
 * The `vocdoni` voting backend for Decidim's client-side booth. Authenticates
 * the voter against the Vocdoni CSP with the credentials the server put in the
 * booth config, runs the email OTP when the census asks for it, and casts each
 * question from the browser with `cast.js`.
 *
 * Config (from the gem's `booth_config`): apiUrl, processId, chainId,
 * explorerUrl, credentials, contact, questions, i18n.
 *
 * Adapter contract (all async):
 *   prepare(ctx)  -> { canVote, alreadyVoted, receipts?, priorReceipts?,
 *                      pendingQuestionIds?, message? }
 *   cast(ctx, ballot) -> { receipts, unconfirmed, failed }
 *   recheck(ctx)  -> { receipts } — re-fetches CSP receipts; call after
 *                    an unconfirmed result to see whether the vote landed.
 */
const NAME = "vocdoni";
const REGISTERED_EVENT = "decidim:voting-backend:registered";

const interpolate = (text, values = {}) => String(text || "").replace(/%\{(\w+)\}/g, (match, key) => (key in values
  ? values[key]
  : ""));

const message = (i18n, error) => {
  const errors = (i18n && i18n.errors) || {};
  const code = error && error.code;

  if (code && errors[code]) {
    return interpolate(errors[code], error.details || {});
  }

  return errors.unknown || String(error && error.message);
};

const verifyUrl = (config, nullifier) => (config.explorerUrl
  ? `${config.explorerUrl.replace(/\/+$/, "")}/verify/#/${nullifier}`
  : null);

const createAdapter = () => {
  let flow = null;
  let questionsByDecidimId = new Map();

  const receiptsFrom = (config, consumed) => {
    const byVocdoniId = new Map(config.questions.map((question) => [question.vocdoniQuestionId, question]));

    return consumed.
      map((item) => {
        const question = byVocdoniId.get(item.questionId);
        const code = item.nullifier || item.voteId || item.voteID;

        return question && code
          ? { questionId: question.questionId, code, verifyUrl: verifyUrl(config, code) }
          : null;
      }).
      filter(Boolean);
  };

  // Shows the OTP panel and resolves once the CSP accepts a code. Progress
  // goes to the booth's status line; errors go under the field, the way
  // Decidim's form builder shows them.
  const runOtp = (ctx) => new Promise((resolve) => {
    const { i18n } = ctx.config;
    const panel = ctx.showPanel();
    const form = panel.querySelector("[data-vocdoni-otp-form]");
    const input = panel.querySelector("[data-vocdoni-otp-code]");
    const feedback = panel.querySelector("[data-vocdoni-otp-feedback]");
    const resend = panel.querySelector("[data-vocdoni-otp-resend]");
    const label = input.closest("label");
    let cooldownTimer = null;

    const showError = (text) => {
      feedback.textContent = text || "";
      feedback.classList.toggle("is-visible", Boolean(text));
      input.classList.toggle("is-invalid-input", Boolean(text));
      if (label) {
        label.classList.toggle("is-invalid-label", Boolean(text));
      }
    };

    const cooldown = (seconds) => {
      resend.disabled = true;
      let left = seconds;
      clearInterval(cooldownTimer);
      cooldownTimer = setInterval(() => {
        left -= 1;
        resend.textContent = left > 0
          ? interpolate(i18n.otp.resend_wait, { seconds: left })
          : i18n.otp.resend;
        if (left <= 0) {
          clearInterval(cooldownTimer);
          resend.disabled = false;
        }
      }, 1000);
    };

    cooldown(30);
    input.focus();

    resend.addEventListener("click", async () => {
      showError("");
      ctx.progress(i18n.status.sending_code);
      try {
        await flow.resendOtp();
        ctx.progress(i18n.otp.resent);
        cooldown(30);
      } catch (error) {
        ctx.progress("");
        showError(message(i18n, error));
      }
    });

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const code = input.value.trim();
      if (!code) {
        showError(i18n.otp.required);
        return;
      }
      showError("");
      ctx.progress(i18n.status.authenticating);
      try {
        await flow.confirmOtp(code);
        clearInterval(cooldownTimer);
        ctx.progress("");
        resolve();
      } catch (error) {
        ctx.progress("");
        showError(message(i18n, error));
        if (error.code === ErrorCode.OTP_EXPIRED) {
          resend.disabled = false;
        }
      }
    });
  });

  return {
    async prepare(ctx) {
      const { config } = ctx;
      const { i18n } = config;

      if (!config.processId) {
        return { canVote: false, alreadyVoted: false, message: i18n.not_ready };
      }

      questionsByDecidimId = new Map(config.questions.map((question) => [String(question.questionId), question]));
      flow = createVoterFlow({ apiUrl: config.apiUrl, processId: config.processId, chainId: config.chainId });

      try {
        ctx.progress(i18n.status.loading);
        await flow.loadProcess();

        ctx.progress(i18n.status.authenticating);
        const channel = flow.twoFaChannels()[0] || null;
        const { needsOtp } = await flow.authenticate(config.credentials, channel
          ? { channel, contact: (config.contact || {})[channel] }
          : {});

        if (needsOtp) {
          ctx.progress("");
          await runOtp(ctx);
        }

        ctx.progress(i18n.status.checking);
        const check = await flow.check();

        if (!check.belongsToProcess) {
          return { canVote: false, alreadyVoted: false, message: i18n.blocked.not_in_census.body };
        }

        check.questions.forEach((remote) => {
          const local = config.questions.find((question) => question.vocdoniQuestionId === remote.questionId);
          if (local) {
            local.upstreamId = remote.upstreamId || local.upstreamId;
            local.canVote = Boolean(remote.canVote);
            local.hasVoted = Boolean(remote.hasVoted);
          }
        });

        const voted = config.questions.filter((question) => question.hasVoted);
        const stillVotable = config.questions.filter((question) => question.canVote && !question.hasVoted);

        if (voted.length > 0 && stillVotable.length === 0) {
          // Every question has a recorded vote — show the receipt.
          return { canVote: false, alreadyVoted: true, receipts: receiptsFrom(config, await flow.receipts()) };
        }

        if (voted.length > 0 && stillVotable.length > 0) {
          // Some questions are already cast; let the voter finish the rest.
          return {
            canVote: true,
            alreadyVoted: false,
            priorReceipts: receiptsFrom(config, await flow.receipts()),
            pendingQuestionIds: stillVotable.map((question) => String(question.questionId))
          };
        }

        if (!config.questions.some((question) => question.canVote)) {
          return { canVote: false, alreadyVoted: false, message: i18n.blocked.not_open.body };
        }

        return { canVote: true, alreadyVoted: false };
      } catch (error) {
        throw new Error(message(i18n, error));
      }
    },

    /**
     * Casts all votable ballot entries. Never throws: errors per question are
     * collected into `unconfirmed` (RELAY_UNCONFIRMED — the vote may have
     * landed) or `failed` (definitive failure — safe to retry).
     *
     * @param {Object} ctx - booth context (config, i18n, progress).
     * @param {Array} ballot - `[{ questionId, responseOptionIds }]` for every question.
     * @returns {Promise<{receipts: Array, unconfirmed: Array, failed: Array}>} per-question outcome.
     */
    async cast(ctx, ballot) {
      const { config } = ctx;
      const { i18n } = config;
      const receipts = [];
      const unconfirmed = [];
      const failed = [];

      const votable = ballot.filter((entry) => {
        const question = questionsByDecidimId.get(String(entry.questionId));

        return question && question.canVote;
      });

      for (const entry of votable) {
        const question = questionsByDecidimId.get(String(entry.questionId));
        const selectedValues = entry.responseOptionIds.
          map((id) => question.choices[String(id)]).
          filter((value) => typeof value === "number");

        try {
          const { nullifier } = await flow.castQuestion({
            questionId: question.vocdoniQuestionId,
            upstreamId: question.upstreamId,
            selectedValues,
            onProgress: (phase) => ctx.progress(`${question.title}: ${i18n.status[phase] || phase}`)
          });
          receipts.push({ questionId: question.questionId, code: nullifier, verifyUrl: verifyUrl(config, nullifier) });
        } catch (error) {
          // Use the error's own code when present (duck-type, avoids cross-module
          // instanceof mismatches in test environments).
          const code = error && typeof error.code === "string"
            ? error.code
            : ErrorCode.UNKNOWN;

          if (code === ErrorCode.RELAY_UNCONFIRMED) {
            unconfirmed.push({ questionId: question.questionId, label: question.title });
          } else {
            failed.push({ questionId: question.questionId, label: question.title, error: message(i18n, error) });
          }
        }
      }

      return { receipts, unconfirmed, failed };
    },

    /**
     * Re-fetches the CSP receipt store. Call this after an unconfirmed result
     * to find out whether the vote arrived on chain in the meantime.
     *
     * @param {Object} ctx - booth context (config).
     * @returns {Promise<{receipts: Array}>} only the questions that now have a receipt.
     */
    async recheck(ctx) {
      const { config } = ctx;

      try {
        const consumed = await flow.receipts();

        return { receipts: receiptsFrom(config, consumed) };
      } catch {
        return { receipts: [] };
      }
    }
  };
};

window.Decidim = window.Decidim || {};
window.Decidim.votingBackends = window.Decidim.votingBackends || {};
window.Decidim.votingBackends[NAME] = createAdapter();
document.dispatchEvent(new CustomEvent(REGISTERED_EVENT, { detail: { name: NAME } }));
