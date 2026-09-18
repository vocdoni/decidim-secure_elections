import { LOCALE_PATTERN } from "src/decidim/elections/vocdoni/voter/params";

/**
 * The voting page's translations, shipped as JSON next to the page.
 *
 * The voting page has no server behind it, so it cannot be handed a rendered string.
 * Instead the gem ships one JSON file per locale under `locales/`, generated
 * from `config/locales/*.yml` at build time, plus an `index.json` naming the
 * ones that exist. The voting page reads the index once and then fetches exactly one
 * translation file — no 404 hunting, and no guessing which locales a given
 * release happens to carry.
 *
 * Which locale:
 *
 *   1. `?locale=` when the link says so (Decidim passes the voter's own),
 *   2. otherwise `navigator.languages`, in the browser's order of preference,
 *   3. otherwise English.
 *
 * Region subtags are honoured when a file exists for them (`pt-BR`) and fall
 * back to the base language when one does not (`pt-BR` → `pt`).
 */

const DEFAULT_LOCALE = "en";

/**
 * Normalizes a locale tag for comparison: `pt_br` and `PT-BR` are the same
 * thing, and neither is what the file is called.
 *
 * @param {string} tag - a locale tag.
 * @returns {string} the lower-cased, dash-separated tag.
 */
const normalize = (tag) => String(tag || "").trim().replace(/_/g, "-").toLowerCase();

/**
 * The locales to try, best first: the requested one, then what the browser
 * asks for, then English. Each tag also contributes its base language, so a
 * `ca-ES` browser is served the `ca` file.
 *
 * @param {string} [requested] - the `?locale=` parameter.
 * @param {string[]} [languages] - `navigator.languages`.
 * @returns {string[]} the candidate tags, de-duplicated and in order.
 */
export const localeCandidates = (requested, languages = []) => {
  const ordered = [requested, ...Array.from(languages || []), DEFAULT_LOCALE].
    filter((tag) => typeof tag === "string" && LOCALE_PATTERN.test(tag.replace(/_/g, "-")));

  const expanded = ordered.flatMap((tag) => {
    const normalized = normalize(tag);
    const base = normalized.split("-")[0];

    return normalized === base
      ? [normalized]
      : [normalized, base];
  });

  return Array.from(new Set(expanded));
};

/**
 * The best available locale for a set of candidates.
 *
 * @param {string[]} available - the locales this build actually ships.
 * @param {string[]} candidates - the candidates, best first.
 * @returns {string|null} the locale as it is named in `available`.
 */
export const pickLocale = (available, candidates) => {
  const byNormalized = new Map((available || []).
    filter((tag) => typeof tag === "string").
    map((tag) => [normalize(tag), tag]));

  const match = candidates.find((candidate) => byNormalized.has(candidate));

  return match
    ? byNormalized.get(match)
    : null;
};

/**
 * Fetches a JSON document, refusing anything that is not one.
 *
 * @param {Function} fetchImpl - the fetch implementation to use.
 * @param {string} url - the document URL.
 * @returns {Promise<Object>} the parsed document.
 */
const fetchJson = async (fetchImpl, url) => {
  const response = await fetchImpl(url, { credentials: "omit" });

  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }

  return response.json();
};

/**
 * Loads the translations the voting page should speak.
 *
 * @param {Object} options - loading options.
 * @param {string} options.baseUrl - where the `locales/` directory lives.
 * @param {string} [options.requested] - the `?locale=` parameter.
 * @param {string[]} [options.languages] - `navigator.languages`.
 * @param {Function} [options.fetchImpl] - injectable `fetch`, for tests.
 * @returns {Promise<{locale: string, messages: Object}>} the chosen locale and
 *   its strings.
 */
export const loadTranslations = async ({ baseUrl, requested, languages, fetchImpl = fetch }) => {
  const index = await fetchJson(fetchImpl, `${baseUrl}index.json`);
  const available = Array.isArray(index && index.locales)
    ? index.locales
    : [DEFAULT_LOCALE];

  // English is the build's guaranteed floor, so a candidate list that matches
  // nothing still resolves rather than leaving the voting page speechless.
  const locale = pickLocale(available, localeCandidates(requested, languages)) ||
    pickLocale(available, [DEFAULT_LOCALE]) ||
    DEFAULT_LOCALE;

  const messages = await fetchJson(fetchImpl, `${baseUrl}${locale}.json`);

  return { locale, messages };
};

export default loadTranslations;
