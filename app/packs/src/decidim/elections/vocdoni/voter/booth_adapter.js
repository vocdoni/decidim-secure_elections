import { notifyVoteCast } from "src/decidim/elections/vocdoni/voter/cast_notification";
import { createVoterFlow } from "src/decidim/elections/vocdoni/voter/flow";
import { ErrorCode } from "src/decidim/elections/vocdoni/voter/errors";
import { message } from "src/decidim/elections/vocdoni/voter/booth_text";
import { runOtp } from "src/decidim/elections/vocdoni/voter/booth_otp";
import { createNextQuestionWatcher, holdUntilOpen } from "src/decidim/elections/vocdoni/voter/per_question";

/**
 * The `vocdoni` voting backend for Decidim's client-side booth. Authenticates
 * the voter against the Vocdoni CSP with the credentials the server put in the
 * booth config, runs the email OTP when the census asks for it, and casts each
 * question from the browser with `cast.js`.
 *
 * Config (from the gem's `booth_config`): apiUrl, processId, chainId,
 * explorerUrl, credentials, contact, questions, i18n; and for a per-question
 * election perQuestion, waitingUrl, perQuestionI18n (see `per_question.js`).
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

const verifyUrl = (config, nullifier) => (config.explorerUrl
  ? `${config.explorerUrl.replace(/\/+$/, "")}/verify/#/${nullifier}`
  : null);

const createAdapter = () => {
  let flow = null;
  let questionsByDecidimId = new Map();
  // Per-question: once the open questions are cast, wait for the next one.
  const watchNext = createNextQuestionWatcher();

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

  // One CSP session per page. The token covers every question of the
  // process, so when `prepare` runs again for a question opened in place
  // (`fresh` false) a verified session is reused: no new one-time code.
  const openSession = async (ctx, { fresh }) => {
    const { config } = ctx;
    const { i18n } = config;

    ctx.progress(i18n.status.loading);
    if (!fresh && flow && flow.verified) {
      return flow.loadProcess();
    }

    flow = createVoterFlow({ apiUrl: config.apiUrl, processId: config.processId, chainId: config.chainId });
    const loaded = await flow.loadProcess();

    ctx.progress(i18n.status.authenticating);
    const channel = flow.twoFaChannels()[0] || null;
    const { needsOtp } = await flow.authenticate(config.credentials, channel
      ? { channel, contact: (config.contact || {})[channel] }
      : {});

    if (needsOtp) {
      ctx.progress("");
      await runOtp(ctx, flow);
    }

    return loaded;
  };

  return {
    async prepare(ctx) {
      const { config } = ctx;
      const { i18n } = config;

      if (!config.processId) {
        return { canVote: false, alreadyVoted: false, message: i18n.not_ready };
      }

      questionsByDecidimId = new Map(config.questions.map((question) => [String(question.questionId), question]));
      const reused = Boolean(flow && flow.verified);

      try {
        let loaded = await openSession(ctx, { fresh: false });

        ctx.progress(i18n.status.checking);
        let check = null;
        try {
          check = await flow.check();
        } catch (error) {
          if (!reused) {
            throw error;
          }
          // The CSP no longer takes the reused token (a census change drops
          // it, for instance): sign in again on this page.
          loaded = await openSession(ctx, { fresh: true });
          check = await flow.check();
        }

        if (!check.belongsToProcess) {
          return { canVote: false, alreadyVoted: false, message: i18n.blocked.not_in_census.body };
        }

        check.questions.forEach((remote) => {
          const local = config.questions.find((question) => question.vocdoniQuestionId === remote.questionId);
          if (local) {
            local.upstreamId = remote.upstreamId || local.upstreamId;
            // A question whose results are out is no longer on the booth page.
            local.canVote = Boolean(remote.canVote) && !local.closed;
            local.hasVoted = Boolean(remote.hasVoted);
          }
        });

        const blocked = await holdUntilOpen(ctx, flow, loaded);
        if (blocked) {
          // Keep watching: the question is retried once it opens on chain.
          watchNext(ctx);

          return { canVote: false, alreadyVoted: false, message: blocked };
        }

        const voted = config.questions.filter((question) => question.hasVoted);
        const stillVotable = config.questions.filter((question) => question.canVote && !question.hasVoted);

        if (voted.length > 0 && stillVotable.length === 0) {
          // Every question has a recorded vote — show the receipt.
          const receipts = receiptsFrom(config, await flow.receipts());
          watchNext(ctx);

          return { canVote: false, alreadyVoted: true, receipts };
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

      if (receipts.length > 0 || unconfirmed.length > 0) {
        notifyVoteCast(config.castNotificationUrl);
      }
      if (unconfirmed.length === 0 && failed.length === 0) {
        watchNext(ctx);
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
