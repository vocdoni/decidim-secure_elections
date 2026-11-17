/**
 * Cast-time gate for a per-question booth. The booth page lists the questions
 * open when it was rendered; the admin may close one (publish its results)
 * while the voter fills in the ballot, and its ballot must not be cast then.
 */

/**
 * The Decidim ids of the questions open in Decidim now, read from
 * `waiting.json`; null for other elections or when it cannot be read.
 *
 * @param {Object} config - the booth config.
 * @returns {Promise<Set<string>|null>} open question ids.
 */
export const openQuestionIds = async (config) => {
  if (!config.perQuestion || !config.waitingUrl) {
    return null;
  }
  try {
    const response = await fetch(config.waitingUrl, { credentials: "same-origin", headers: { Accept: "application/json" } });
    if (response.ok === false) {
      return null;
    }
    const data = await response.json();

    return Array.isArray(data.open_question_ids)
      ? new Set(data.open_question_ids.map(String))
      : null;
  } catch {
    return null;
  }
};

/**
 * Drops the ballot entries for questions Decidim has closed since the booth was prepared, and marks those
 * questions `closed`. When Decidim's answer cannot be read the entries are
 * kept: the chain status is what finally accepts or rejects a ballot.
 *
 * @param {Object} config - the booth config.
 * @param {Array} entries - `[{ entry, question }]` about to be cast.
 * @returns {Promise<{open: Array, closed: Array}>} entries to cast and to refuse.
 */
export const splitClosed = async (config, entries) => {
  const open = await openQuestionIds(config);
  if (!open) {
    return { open: entries, closed: [] };
  }

  const closed = entries.filter(({ question }) => !open.has(String(question.questionId)));
  closed.forEach(({ question }) => {
    question.closed = true;
    question.canVote = false;
  });

  return { open: entries.filter((item) => !closed.includes(item)), closed };
};

/**
 * The message for a question closed before its ballot was cast.
 *
 * @param {Object} config - the booth config.
 * @returns {string} the message.
 */
export const closedMessage = (config) => (config.perQuestionI18n || {}).closed || config.i18n.blocked.not_open.body;
