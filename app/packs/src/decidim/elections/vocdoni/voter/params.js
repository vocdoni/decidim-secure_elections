/**
 * The voting page's only inputs, read from its own query string.
 *
 * The voting page is a static page: nothing is rendered for it, nothing is
 * injected into it, and there is no configuration island to read. Everything it
 * needs it either finds here or fetches from the public process read.
 *
 * There are two ways to say the same four things:
 *
 *   /vocdoni/vote.html?v=<base64url>
 *   /vocdoni/vote.html?api=<apiUrl>&process=<processId>[&locale=xx][&exit=/path]
 *
 * `v` is what Decidim mints now — one short, unpunctuated value, described in
 * `link_code.js`. It is an abbreviation and nothing more: anybody can decode it,
 * and nothing here relies on it hiding anything. The plain parameters are still
 * read because links carrying them are already in inboxes.
 *
 * Either way the API base and the process id are required, while `locale` and
 * `exit` are conveniences: a missing locale is negotiated from the browser, and
 * a missing exit simply means the page shows no way back.
 *
 * Every value is validated below before use, whichever form it arrived in.
 * Not because a voter would attack their own ballot, but because the link is
 * built elsewhere (by Decidim, by an email, by hand) and a page that follows
 * whatever it is handed can be pointed at somebody else's API or turned into a
 * redirector.
 */

import { API_HOSTS, decodeLink } from "src/decidim/elections/vocdoni/voter/link_code";

/** A Vocdoni process id is a Mongo ObjectID — ARCHITECTURE §1. */
const PROCESS_ID_PATTERN = /^[0-9a-f]{24}$/i;

/** BCP-47-ish, and deliberately strict: this value ends up in a fetch path. */
export const LOCALE_PATTERN = /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/;

/** Where plain HTTP is not a mistake, because there is no network to sniff. */
const LOOPBACK_HOSTS = ["localhost", "127.0.0.1", "[::1]"];

/**
 * Whether this page may send a census credential to that origin.
 *
 * This is the load-bearing check on the page, and it is worth being explicit
 * about why. The voting page is served from the Decidim installation's own
 * domain, and it takes the API it talks to from its own query string. Without
 * this check, anybody could mint
 *
 *   https://<trusted-decidim>/vocdoni/vote.html?api=https://attacker.example&process=…
 *
 * mail it to a census, and collect every credential and one-time code typed
 * into it — on a domain the voters have been taught to trust, which is exactly
 * the domain that makes the usual "check the address bar" advice fail.
 *
 * Three kinds of origin are allowed, and nothing else:
 *
 *   1. the Vocdoni SaaS bases this build knows (`API_HOSTS` in `link_code.js`),
 *      which is what `Decidim::Elections::Vocdoni.api_url` is expected to be set to;
 *   2. this page's own origin, for an installation that reverse-proxies the API
 *      under its own domain — that origin is already trusted with the page
 *      itself, so it cannot be a downgrade;
 *   3. loopback, so the flow can be developed against a local API.
 *
 * An installation whose API is on some fourth origin has to add it to
 * `API_HOSTS` and rebuild the page. That is deliberate: this list is the whole
 * of the page's trust, and it should be a thing somebody edits on purpose.
 *
 * @param {URL} url - the parsed API base.
 * @param {Location|URL} location - the voting page's own location.
 * @returns {boolean} true when the origin may be talked to.
 */
const isAllowedApiOrigin = (url, location) => {
  if (Object.values(API_HOSTS).some((known) => known === `${url.origin}${url.pathname}`.replace(/\/+$/, "") || known === url.origin)) {
    return true;
  }

  if (location && url.origin === location.origin) {
    return true;
  }

  return LOOPBACK_HOSTS.includes(url.hostname) || LOOPBACK_HOSTS.includes(`[${url.hostname}]`);
};

/**
 * The API base URL, reduced to scheme, host, port and path.
 *
 * Anything that is not an absolute `https` URL on an allowed origin is refused
 * rather than guessed at. A relative value would silently resolve against this
 * Decidim installation; a foreign one turns the page into a credential
 * collector. See {@link isAllowedApiOrigin}.
 *
 * @param {string} value - the raw `api` parameter.
 * @param {Location|URL} [location] - the voting page's own location.
 * @returns {string|null} the normalized base URL, or null when unusable.
 */
export const sanitizeApiUrl = (value, location = null) => {
  if (typeof value !== "string" || value.trim() === "") {
    return null;
  }

  let url = null;

  try {
    url = new URL(value.trim());
  } catch {
    return null;
  }

  // Credentials and one-time codes travel over this. Plain HTTP is refused
  // everywhere a network exists to listen on.
  const loopback = LOOPBACK_HOSTS.includes(url.hostname);

  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) {
    return null;
  }

  if (!isAllowedApiOrigin(url, location)) {
    return null;
  }

  // A query or a fragment on an API base is always a mistake, and would be
  // appended to every request path. Drop them.
  return `${url.origin}${url.pathname}`.replace(/\/+$/, "");
};

/**
 * The process id, or null when it is not one.
 *
 * @param {string} value - the raw `process` parameter.
 * @returns {string|null} the 24-hex process id.
 */
export const sanitizeProcessId = (value) => {
  const candidate = typeof value === "string"
    ? value.trim()
    : "";

  return PROCESS_ID_PATTERN.test(candidate)
    ? candidate.toLowerCase()
    : null;
};

/**
 * The requested locale, or null.
 *
 * @param {string} value - the raw `locale` parameter.
 * @returns {string|null} the locale tag.
 */
export const sanitizeLocale = (value) => {
  const candidate = typeof value === "string"
    ? value.trim().replace(/_/g, "-")
    : "";

  return LOCALE_PATTERN.test(candidate)
    ? candidate
    : null;
};

/**
 * The "leave the voting page" target, restricted to this origin.
 *
 * The voting page is served from the Decidim installation and goes back to it. A
 * cross-origin exit would turn a link somebody is trusted to click — right
 * after typing their census credentials — into a redirector to anywhere.
 *
 * @param {string} value - the raw `exit` parameter.
 * @param {Location|URL} location - the voting page's own location.
 * @returns {string|null} a same-origin URL, or null.
 */
export const sanitizeExitUrl = (value, location) => {
  if (typeof value !== "string" || value.trim() === "") {
    return null;
  }

  let url = null;

  try {
    url = new URL(value.trim(), location.href);
  } catch {
    return null;
  }

  if (url.origin !== location.origin) {
    return null;
  }

  return `${url.pathname}${url.search}${url.hash}`;
};

/**
 * The four fields, in whichever form the link carried them.
 *
 * A `v` that will not decode yields nothing at all rather than falling back to
 * the plain parameters: a link carrying both is a link that has been tampered
 * with, and the honest answer to it is the same "incomplete link" a voter gets
 * for a link carrying neither.
 *
 * @param {URLSearchParams} query - the query string.
 * @returns {Object} `{ api, process, locale, exit }`, raw and unvalidated.
 */
const readFields = (query) => {
  const packed = query.get("v");

  if (packed !== null) {
    return decodeLink(packed) || {};
  }

  return {
    api: query.get("api"),
    process: query.get("process"),
    locale: query.get("locale"),
    exit: query.get("exit")
  };
};

/**
 * Reads every parameter the voting page accepts.
 *
 * @param {Location|URL} [location] - the voting page's own location.
 * @returns {Object} `{ apiUrl, processId, locale, exitUrl }`.
 */
export const readParams = (location = window.location) => {
  const fields = readFields(new URLSearchParams(location.search));

  return {
    apiUrl: sanitizeApiUrl(fields.api, location),
    processId: sanitizeProcessId(fields.process),
    locale: sanitizeLocale(fields.locale),
    exitUrl: sanitizeExitUrl(fields.exit, location)
  };
};

/**
 * Whether the voting page has what it needs to talk to the API at all.
 *
 * @param {Object} params - the parsed parameters.
 * @returns {boolean} true when the voting page can start.
 */
export const isUsable = (params) => Boolean(params && params.apiUrl && params.processId);

export default readParams;
