import { createVotingPage } from "src/decidim/elections/vocdoni/voter/voting_page";
import { byId, toggle } from "src/decidim/elections/vocdoni/voter/dom";
import { isUsable, readParams } from "src/decidim/elections/vocdoni/voter/params";
import { loadTranslations } from "src/decidim/elections/vocdoni/voter/i18n";
import { createThemeToggle } from "src/decidim/elections/vocdoni/voter/theme";

/**
 * The static voting page's entry point.
 *
 * This is bundled — dependencies and all — into `public/vocdoni/vote.js` and
 * loaded by `public/vocdoni/vote.html`. There is no Rails view, no Shakapacker
 * manifest and no host application involved: the page is served straight off
 * disk by the engine's static middleware, and everything below runs from the
 * query string outwards.
 *
 * Everything here runs in the voter's browser and touches census credentials, an
 * ephemeral private key and the cleartext ballot. See ARCHITECTURE §0: nothing may
 * log, persist or transmit any of them anywhere other than the Vocdoni API.
 */

/** Languages written right to left, so the page can say so before anything renders. */
const RTL_LANGUAGES = ["ar", "arc", "dv", "fa", "ha", "he", "khw", "ks", "ku", "ps", "sd", "ur", "yi"];

/**
 * The writing direction for a locale.
 *
 * @param {string} locale - the locale in use.
 * @returns {string} `rtl` or `ltr`.
 */
export const directionFor = (locale) => (RTL_LANGUAGES.includes(String(locale || "").toLowerCase().split("-")[0])
  ? "rtl"
  : "ltr");

/**
 * Starts the voting page, or explains why it could not start.
 *
 * The two failures handled here are the only ones that can happen before the
 * voting page has a vocabulary to describe anything: a link that does not carry an API
 * and a process, and a translation file that could not be fetched. Both fall
 * back to a message that is *static markup* in `vote.html`, in English,
 * precisely so that it does not depend on either.
 *
 * They get a message each because their answers are opposite. A translation
 * file that would not load may well load next time, so "reload the page" is
 * useful advice. A link that arrived without its parameters will arrive without
 * them every time it is opened; telling that voter to reload is telling them to
 * do the one thing that cannot possibly work.
 *
 * @returns {Promise<void>} nothing.
 */
export const boot = async () => {
  const root = byId("js-vocdoni-vote");

  // Before anything that can fail: the two screens below are the ones a voter
  // reads when the page could not start, and they are entitled to the theme
  // they asked their operating system for just as much as a ballot is.
  const theme = createThemeToggle({
    button: byId("js-vocdoni-theme"),
    label: byId("js-vocdoni-theme-label")
  });

  if (!root) {
    return;
  }

  const params = readParams();

  const stop = (id) => {
    toggle(root, false);
    toggle(byId(id), true);
  };

  const unavailable = () => stop("js-vocdoni-vote-unavailable");

  if (!isUsable(params)) {
    stop("js-vocdoni-vote-incomplete");

    return;
  }

  let translations = null;

  try {
    translations = await loadTranslations({
      // Relative to the page, so the voting page works wherever the engine's static
      // files end up being mounted.
      baseUrl: new URL("locales/", window.location.href).toString(),
      requested: params.locale,
      languages: window.navigator.languages
    });
  } catch {
    unavailable();

    return;
  }

  document.documentElement.lang = translations.locale;
  document.documentElement.dir = directionFor(translations.locale);
  theme.applyLabel(translations.messages);

  await createVotingPage({
    root,
    params,
    i18n: translations.messages,
    locale: translations.locale,
    statusNode: byId("js-vocdoni-vote-status"),
    titleNode: byId("js-vocdoni-election-title"),
    exitNode: byId("js-vocdoni-election-exit")
  }).start();
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
