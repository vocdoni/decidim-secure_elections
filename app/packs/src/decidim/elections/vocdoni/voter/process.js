/**
 * The public process read, turned into what the voting page renders.
 *
 * `GET /processes/{id}` is unauthenticated (ARCHITECTURE §2) and carries
 * everything the voting page needs: the title and description, the chain id, the
 * census `authFields` and `twoFaFields`, the dates, and every question with its
 * choices, its type, its `upstreamId` and its status. That is the whole reason
 * the voting page can be a static page — there is nothing left for a server to tell
 * it.
 *
 * Two things are deliberately *not* taken from here:
 *
 *   * eligibility, which is `processes.check` and nothing else;
 *   * `upstreamId` for signing, which is read from `check` per voter and only
 *     falls back to the process read.
 */

/** Statuses that mean "this is not accepting ballots right now". */
const CLOSED_STATUSES = ["DRAFT", "PAUSED", "ENDED", "RESULTS", "CANCELED", "CANCELLED"];

/**
 * Builds a resolver for the API's language maps.
 *
 * Titles arrive as `{ default: "…", en: "…", ca: "…" }` (ARCHITECTURE §2.1). The
 * voting page resolves them against the locale it is actually speaking, falls back to
 * the base language, then to the `default` the API guarantees, and finally to
 * any value at all — an election whose only translation is Catalan should still
 * be readable rather than blank.
 *
 * @param {string} locale - the locale the voting page is rendering in.
 * @returns {Function} a `(value) => string` resolver.
 */
export const localizer = (locale) => {
  const wanted = String(locale || "en").replace(/_/g, "-").toLowerCase();
  const base = wanted.split("-")[0];

  return (value) => {
    if (typeof value === "string") {
      return value;
    }

    if (!value || typeof value !== "object") {
      return "";
    }

    const byLocale = new Map(Object.entries(value).
      filter(([, text]) => typeof text === "string" && text.trim() !== "").
      map(([tag, text]) => [tag.replace(/_/g, "-").toLowerCase(), text]));

    return byLocale.get(wanted) ||
      byLocale.get(base) ||
      byLocale.get("default") ||
      Array.from(byLocale.values())[0] ||
      "";
  };
};

/**
 * A timestamp as milliseconds, or null when absent or unparseable.
 *
 * @param {string} value - an ISO 8601 timestamp.
 * @returns {number|null} the epoch milliseconds.
 */
const timeOf = (value) => {
  if (typeof value !== "string" || value.trim() === "") {
    return null;
  }

  const parsed = Date.parse(value);

  return Number.isFinite(parsed)
    ? parsed
    : null;
};

/**
 * The upper bound on a multichoice question's selection.
 *
 * @param {number} declared - `typeSetup.maxChoices`, possibly absent.
 * @param {number} available - how many choices the question offers.
 * @returns {number} the effective maximum.
 */
const multiChoiceMax = (declared, available) => (Number.isFinite(declared) && declared > 0
  ? declared
  : available);

/**
 * Normalizes one question of the process read.
 *
 * @param {Object} raw - the question as the API returns it.
 * @param {number} index - its position in the ballot.
 * @param {Function} localize - the language-map resolver.
 * @returns {Object} the voting page's view of the question.
 */
const normalizeQuestion = (raw, index, localize) => {
  const choices = (Array.isArray(raw.choices)
    ? raw.choices
    : []).
    map((choice) => ({
      value: Number(choice.value),
      title: localize(choice.title)
    })).
    filter((choice) => Number.isFinite(choice.value));

  const type = String(raw.type || "").toLowerCase();
  const setup = raw.typeSetup || {};
  const min = Number(setup.minChoices);
  const max = Number(setup.maxChoices);

  return {
    index,
    // The id of the question *inside the process*. The id used to sign and to
    // vote is `upstreamId` — ARCHITECTURE §1.
    vocdoniQuestionId: raw.id || raw.questionId || null,
    // Present on the public read, but only used as a fallback: `check` answers
    // with the ids this particular voter may sign against.
    processUpstreamId: raw.upstreamId || null,
    title: localize(raw.title),
    description: localize(raw.description),
    type,
    minChoices: type === "multichoice" && Number.isFinite(min) && min > 0
      ? min
      : 1,
    // A multichoice question with no `typeSetup` may pick anything up to every
    // choice there is; a singlechoice one always picks exactly one.
    maxChoices: type === "multichoice"
      ? multiChoiceMax(max, choices.length)
      : 1,
    secret: Boolean(raw.secretUntilTheEnd),
    status: String(raw.status || "").toUpperCase(),
    choices
  };
};

/**
 * Normalizes the process read.
 *
 * @param {Object} raw - the process as the API returns it.
 * @param {string} locale - the locale the voting page is rendering in.
 * @returns {Object} the voting page's view of the election.
 */
export const normalizeProcess = (raw, locale) => {
  const localize = localizer(locale);
  const process = raw || {};
  const census = process.census || {};

  return {
    id: process.id || null,
    title: localize(process.title),
    description: localize(process.description),
    chainId: process.chainId || null,
    status: String(process.status || "").toUpperCase(),
    startsAt: timeOf(process.startDate),
    endsAt: timeOf(process.endDate),
    authFields: Array.isArray(census.authFields)
      ? census.authFields
      : [],
    twoFaFields: Array.isArray(census.twoFaFields)
      ? census.twoFaFields
      : [],
    censusSize: Number.isFinite(Number(census.size))
      ? Number(census.size)
      : null,
    questions: (Array.isArray(process.questions)
      ? process.questions
      : []).
      map((question, index) => normalizeQuestion(question, index, localize)).
      filter((question) => question.vocdoniQuestionId)
  };
};

/**
 * Whether this election looks open for voting.
 *
 * Only used to warn the voter before they identify themselves; the authority is
 * still `processes.check`, which answers per voter and per question. Getting
 * this wrong in the permissive direction therefore costs an honest "there is
 * nothing open for you" a screen later, not a wrong ballot.
 *
 * @param {Object} process - a normalized process.
 * @param {number} [now] - the current time, injectable for tests.
 * @returns {boolean} true when the voting page should invite the voter to vote.
 */
export const isVotingOpen = (process, now = Date.now()) => {
  if (!process || process.questions.length === 0) {
    return false;
  }

  if (process.startsAt !== null && now < process.startsAt) {
    return false;
  }

  if (process.endsAt !== null && now > process.endsAt) {
    return false;
  }

  if (CLOSED_STATUSES.includes(process.status)) {
    return false;
  }

  // A question with no status at all is treated as open: an older process read
  // that omits it must not lock a live election out of its own voting page.
  return process.questions.some((question) => !CLOSED_STATUSES.includes(question.status));
};

export default normalizeProcess;
