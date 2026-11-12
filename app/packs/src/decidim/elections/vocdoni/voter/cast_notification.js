/**
 * Tells Decidim that this voter just cast, so a live-results election pulls
 * the new tally from Vocdoni now instead of on its slow fallback poll. Sends
 * no vote content: the server only enqueues a sync. Best effort — a failure
 * never reaches the voter.
 *
 * @param {string} url - `castNotificationUrl` from the booth config.
 * @param {Object} [deps] - injectable for tests.
 * @param {Function} [deps.fetchFn] - defaults to the global `fetch`.
 * @param {Document} [deps.doc] - where the CSRF meta tag is read from.
 * @returns {Promise<boolean>} whether the server accepted the notification.
 */
export const notifyVoteCast = (url, { fetchFn = globalThis.fetch, doc = globalThis.document } = {}) => {
  if (!url || typeof fetchFn !== "function") {
    return Promise.resolve(false);
  }

  const token = doc && doc.querySelector("meta[name='csrf-token']");
  const headers = { "X-Requested-With": "XMLHttpRequest" };
  if (token && token.content) {
    headers["X-CSRF-Token"] = token.content;
  }

  return Promise.resolve().
    then(() => fetchFn(url, { method: "POST", headers, credentials: "same-origin", keepalive: true })).
    then((response) => Boolean(response && response.ok)).
    catch(() => false);
};
