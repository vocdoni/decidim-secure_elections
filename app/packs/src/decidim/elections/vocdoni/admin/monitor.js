/**
 * The monitoring page: "Refresh" that visibly does something.
 *
 * Reading the tally is a background job (ARCHITECTURE §0.5), so pressing refresh
 * cannot answer with new numbers — it can only ask for them. Left alone, that
 * produced the worst possible result: the admin pressed the control, the page
 * came back identical, and the obvious conclusion was that votes were being
 * lost.
 *
 * So the control says it is working, and the figures are swapped in as soon as
 * the job lands. Everything polled here is `monitor.json`, the same local read
 * that renders the page — no request from this file can reach Vocdoni.
 *
 * Without this file the link still works: it enqueues the job and comes back
 * with a flash message, exactly as before.
 */

const WRAPPER_ID = "js-vocdoni-monitor";

// The sync job is a couple of HTTP round trips to the SaaS, so it lands in
// seconds. Polling stops either way — a monitor that polls forever is a monitor
// that quietly hammers the server on a forgotten browser tab.
const POLL_INTERVAL_MS = 2000;
const POLL_TIMEOUT_MS = 30000;

const JSON_HEADERS = { "Accept": "application/json", "X-Requested-With": "XMLHttpRequest" };

/**
 * Sets an element's text, and flags it for one animation cycle when it changed
 * so a figure that moves is seen to move.
 *
 * @param {Element|null} element the element to update.
 * @param {string|undefined} value the new text.
 * @returns {void} nothing.
 */
const updateText = (element, value) => {
  if (!element || typeof value !== "string" || element.textContent === value) {
    return;
  }

  element.textContent = value;
  element.dataset.justUpdated = "true";
  setTimeout(() => Reflect.deleteProperty(element.dataset, "justUpdated"), 1000);
};

/**
 * Applies one polled payload to the page.
 *
 * @param {Element} wrapper the monitor wrapper.
 * @param {Object} data the payload from the status endpoint.
 * @returns {void} nothing.
 */
const applyPayload = (wrapper, data) => {
  updateText(wrapper.querySelector("[data-monitor-turnout]"), data.turnout_text);
  updateText(wrapper.querySelector("[data-monitor-synced]"), data.synced_text);
  updateText(wrapper.querySelector("[data-monitor-upstream-status]"), data.upstream_status);

  // The badge keeps its colour class; only the wording is refreshed, so a
  // paused or ended election is named as such without a reload.
  const stateBadge = wrapper.querySelector("[data-monitor-state] .label");
  updateText(stateBadge, data.state_label);

  const results = document.getElementById("js-vocdoni-monitor-results");

  if (!results) {
    return;
  }

  (data.questions || []).forEach((question) => {
    const node = results.querySelector(`[data-monitor-question="${question.id}"]`);

    if (!node) {
      return;
    }

    updateText(node.querySelector("[data-monitor-question-votes]"), question.votes_text);

    (question.answers || []).forEach((answer) => {
      const row = node.querySelector(`[data-monitor-answer="${answer.id}"]`);

      if (!row) {
        return;
      }

      updateText(row.querySelector("[data-monitor-answer-votes]"), answer.votes_text);
      updateText(row.querySelector("[data-monitor-answer-percent]"), answer.percent_text);
    });
  });
};

const setupMonitor = () => {
  const wrapper = document.getElementById(WRAPPER_ID);
  const button = document.getElementById("js-vocdoni-monitor-refresh");

  if (!wrapper || !button || !wrapper.dataset.statusUrl || !wrapper.dataset.refreshUrl) {
    return;
  }

  const label = button.querySelector("[data-monitor-refresh-label]");
  const feedback = wrapper.querySelector("[data-monitor-feedback]");
  const idleLabel = label
    ? label.textContent
    : "";

  let pending = false;

  const announce = (message) => {
    if (feedback) {
      feedback.textContent = message || "";
    }
  };

  const setPending = (value) => {
    pending = value;
    button.setAttribute("aria-busy", String(value));
    button.setAttribute("aria-disabled", String(value));
    wrapper.dataset.refreshing = String(value);

    if (label) {
      label.textContent = value
        ? wrapper.dataset.refreshingLabel
        : idleLabel;
    }
  };

  /**
   * Reads the local status endpoint once.
   *
   * @returns {Promise<Object|null>} the payload, or null when unreachable.
   */
  const readStatus = async () => {
    try {
      const response = await fetch(wrapper.dataset.statusUrl, { headers: JSON_HEADERS });

      if (!response.ok) {
        return null;
      }

      return await response.json();
    } catch {
      return null;
    }
  };

  /**
   * Polls until the sync job has written a newer reading than the one already
   * on screen, or until we give up. Either way the admin is told which.
   *
   * @param {string|null} previousSyncedAt the timestamp shown before refreshing.
   * @returns {Promise<void>} resolves once the outcome has been announced.
   */
  const waitForSync = async (previousSyncedAt) => {
    const deadline = Date.now() + POLL_TIMEOUT_MS;

    while (Date.now() < deadline) {
      // Sequential on purpose: this is a poll, not a fan-out.
      await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));

      const data = await readStatus();

      if (data) {
        applyPayload(wrapper, data);

        if (data.synced_at && data.synced_at !== previousSyncedAt) {
          announce(wrapper.dataset.refreshedLabel);
          return;
        }
      }
    }

    // The job may still be queued behind others. Saying so is the honest
    // answer; saying nothing is what makes an admin distrust the numbers.
    announce(wrapper.dataset.refreshSlowLabel);
  };

  button.addEventListener("click", async (event) => {
    event.preventDefault();

    if (pending) {
      return;
    }

    setPending(true);
    announce(wrapper.dataset.refreshingLabel);

    const before = await readStatus();
    const previousSyncedAt = before
      ? before.synced_at
      : null;

    try {
      const response = await fetch(wrapper.dataset.refreshUrl, { headers: JSON_HEADERS });
      const body = await response.json();

      if (!response.ok || !body.enqueued) {
        announce(body.message || wrapper.dataset.refreshFailedLabel);
        return;
      }

      await waitForSync(previousSyncedAt);
    } catch {
      announce(wrapper.dataset.refreshFailedLabel);
    } finally {
      setPending(false);
    }
  });
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", setupMonitor);
} else {
  setupMonitor();
}

export default setupMonitor;
