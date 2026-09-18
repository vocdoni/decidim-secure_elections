/**
 * Live refresh of the election page.
 *
 * It polls a Decidim-local JSON endpoint backed by the `results_cache` column
 * (ARCHITECTURE §0.5): no request from this file ever reaches the Vocdoni API, so
 * a busy election page cannot fan out into upstream traffic.
 */

const POLL_INTERVAL_MS = 8000;
const MAX_BACKOFF_MS = 60000;

// How many further polls a closed election gets to settle on its final tally.
// While voting is open the page keeps polling for as long as it is open; once
// it is closed the figures stop moving, so polling has to stop too — but not
// before the refresh the first poll asked for has had a chance to land.
const MAX_SETTLING_POLLS = 5;

/**
 * Sets an element's text and flags it as changed for one animation cycle.
 *
 * @param {Element} element - the element to update.
 * @param {string} value - the new text.
 * @returns {void} nothing.
 */
const updateText = (element, value) => {
  if (!element || element.textContent === value) {
    return;
  }

  element.textContent = value;
  element.dataset.justUpdated = "true";
  setTimeout(() => Reflect.deleteProperty(element.dataset, "justUpdated"), 1000);
};

/**
 * Applies one polled payload to the DOM.
 *
 * @param {Element} container - the results container.
 * @param {Object} data - the payload from the status endpoint.
 * @returns {void} nothing.
 */
const applyResults = (container, data) => {
  updateText(container.querySelector("[data-election-votes-count]"), data.votes_count_text);

  (data.questions || []).forEach((question) => {
    const questionNode = container.querySelector(`[data-results-question="${question.id}"]`);

    if (!questionNode) {
      return;
    }

    updateText(questionNode.querySelector("[data-question-votes-count]"), question.votes_count_text);

    (question.answers || []).forEach((answer) => {
      const answerNode = questionNode.querySelector(`[data-results-answer="${answer.id}"]`);

      if (!answerNode) {
        return;
      }

      updateText(answerNode.querySelector("[data-answer-votes-count]"), answer.votes_count_text);
      updateText(answerNode.querySelector("[data-answer-votes-percent]"), answer.percent_text);

      const bar = answerNode.querySelector("[data-answer-bar]");
      if (bar) {
        bar.style.width = `${answer.percent}%`;
        bar.parentElement.setAttribute("aria-valuenow", String(Math.round(answer.percent)));
      }
    });
  });

  updateText(container.querySelector("[data-results-updated]"), data.synced_at_text);
};

const boot = () => {
  const container = document.getElementById("js-vocdoni-election-results");

  if (!container || !container.dataset.statusUrl) {
    return;
  }

  const url = container.dataset.statusUrl;
  let delay = POLL_INTERVAL_MS;
  let settlingPolls = 0;

  /**
   * One poll cycle, with exponential backoff on failure so a flaky connection
   * does not hammer the server.
   *
   * @returns {Promise<void>}
   */
  const poll = async () => {
    try {
      const response = await fetch(url, {
        headers: { "Accept": "application/json", "X-Requested-With": "XMLHttpRequest" }
      });

      if (!response.ok) {
        throw new Error(`unexpected status ${response.status}`);
      }

      const data = await response.json();
      applyResults(container, data);
      delay = POLL_INTERVAL_MS;

      if (!data.ongoing) {
        settlingPolls += 1;

        // Nothing left to wait for: the tally is closed and up to date.
        if (!data.stale || settlingPolls >= MAX_SETTLING_POLLS) {
          return;
        }
      }
    } catch {
      delay = Math.min(delay * 2, MAX_BACKOFF_MS);
    }

    setTimeout(poll, delay);
  };

  // Straight away, not one interval from now. The server-rendered figures come
  // from the cached tally, and the status endpoint is what asks for that cache
  // to be refreshed — waiting first meant the page sat on a stale number for
  // eight seconds before even starting to catch up.
  poll();
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
