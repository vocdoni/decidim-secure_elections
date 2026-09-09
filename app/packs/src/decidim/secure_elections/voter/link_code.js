/**
 * The packed voting link, `?v=<base64url>`.
 *
 * A voting link is typed off a printed sheet, pasted into a chat window and
 * read out loud, so its length is a usability property. The plain form —
 * `?api=…&exit=…&locale=…&process=…` — spends most of its characters on
 * percent-escaped punctuation and on an API base that is identical for every
 * election on an installation. This module packs the same four fields into one
 * short, unpunctuated value.
 *
 * **This is obfuscation, not security.** Anybody can decode it; that is why
 * `decodeLink` is exported and unit-tested. Nothing may ever be put in here
 * that would matter if it were read, and nothing may rely on it hiding
 * anything. Everything it carries is public by construction: a process id is
 * public on the Vocdoni network, and the rest is a URL and a language tag. What
 * it buys is a link that fits on one line.
 *
 * The layout, all little-endian-free (there are no multi-byte integers):
 *
 *   byte 0        (VERSION << 4) | flags
 *   byte 1…       the API base: one host code, or — when INLINE_API is set — a
 *                 length byte followed by that many UTF-8 bytes
 *   12 bytes      the process id, hex decoded (ARCHITECTURE §1: 24 hex characters)
 *   when LOCALE   a length byte, then that many UTF-8 bytes
 *   when EXIT     the rest of the payload, UTF-8
 *
 * `exit` is last precisely so that it needs no length of its own, and both
 * optional fields are absent — not empty — when they were not supplied. The
 * whole thing is base64url without padding, so the value survives a URL with no
 * `%` escaping.
 *
 * The minimum is 14 bytes, 19 characters: a header, a host code and a process
 * id.
 */

/**
 * The format the encoder writes. A decoder that meets a version it does not
 * know refuses the link rather than guessing at the bytes behind it: the voter
 * then gets "this voting link is incomplete", which is true.
 */
const VERSION = 1;

const FLAG_INLINE_API = 0x01;
const FLAG_LOCALE = 0x02;
const FLAG_EXIT = 0x04;
const KNOWN_FLAGS = FLAG_INLINE_API | FLAG_LOCALE | FLAG_EXIT;

/**
 * API bases worth a single byte, because one installation uses one of them for
 * every election it ever runs.
 *
 * **Append only, and never renumber.** A code is baked into every link already
 * handed out; reusing one would point an old link at a different API. Anything
 * not listed here still works — it travels inline, and the link is longer.
 *
 * The same table exists in `Decidim::SecureElections::VotingPageUrl::API_HOSTS`, which
 * is what writes these links. The two are checked against each other by
 * `link_code.test.js` and `spec/services/decidim/secure_elections/voting_page_url_spec.rb`,
 * which share one fixture value.
 */
export const API_HOSTS = {
  1: "https://saas-api.vocdoni.net",
  2: "https://saas-api-stg.vocdoni.net",
  3: "https://saas-api-dev.vocdoni.net"
};

/** A Vocdoni process id is a Mongo ObjectID — 24 hex characters, 12 bytes. */
const PROCESS_ID_BYTES = 12;

const HEX_PATTERN = /^[0-9a-f]{24}$/i;
const BASE64URL_PATTERN = /^[A-Za-z0-9_-]+$/;

/**
 * The bytes of a base64url value, or null when it is not one.
 *
 * @param {string} value - a base64url string, unpadded or padded.
 * @returns {Uint8Array|null} the bytes.
 */
const fromBase64Url = (value) => {
  if (!BASE64URL_PATTERN.test(value)) {
    return null;
  }

  const padded = value.replace(/-/g, "+").replace(/_/g, "/").
    padEnd(value.length + ((4 - (value.length % 4)) % 4), "=");

  let binary = "";

  try {
    binary = atob(padded);
  } catch {
    return null;
  }

  const bytes = new Uint8Array(binary.length);

  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }

  return bytes;
};

/**
 * The base64url form of some bytes, unpadded.
 *
 * @param {Uint8Array} bytes - the payload.
 * @returns {string} the encoded value.
 */
const toBase64Url = (bytes) => {
  let binary = "";

  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte);
  });

  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/[=]+$/, "");
};

/**
 * A string as UTF-8 bytes.
 *
 * @param {string} value - the string.
 * @returns {Uint8Array} its bytes.
 */
const utf8 = (value) => new TextEncoder().encode(value);

/**
 * Packs the fields a voting link carries.
 *
 * Exported for the round-trip test and for anybody who needs to check what a
 * link says; the links Decidim hands out are built server side by
 * `Decidim::SecureElections::VotingPageUrl`, which writes exactly this layout.
 *
 * @param {Object} fields - the link's contents.
 * @param {string} fields.api - the API base URL.
 * @param {string} fields.process - the 24-hex process id.
 * @param {string} [fields.locale] - a language tag.
 * @param {string} [fields.exit] - where "back to the election" goes.
 * @returns {string|null} the `v` value, or null when the fields cannot be packed.
 */
export const encodeLink = ({ api, process, locale, exit } = {}) => {
  if (typeof api !== "string" || !HEX_PATTERN.test(String(process || ""))) {
    return null;
  }

  const code = Number(Object.keys(API_HOSTS).find((key) => API_HOSTS[key] === api)) || null;
  const parts = [];
  let flags = 0;

  if (code) {
    parts.push(Uint8Array.of(code));
  } else {
    const bytes = utf8(api);

    if (bytes.length > 255) {
      return null;
    }

    flags |= FLAG_INLINE_API;
    parts.push(Uint8Array.of(bytes.length), bytes);
  }

  parts.push(Uint8Array.from(process.toLowerCase().match(/../g).map((pair) => parseInt(pair, 16))));

  if (locale) {
    const bytes = utf8(locale);

    if (bytes.length > 255) {
      return null;
    }

    flags |= FLAG_LOCALE;
    parts.push(Uint8Array.of(bytes.length), bytes);
  }

  if (exit) {
    flags |= FLAG_EXIT;
    parts.push(utf8(exit));
  }

  const size = parts.reduce((total, part) => total + part.length, 1);
  const payload = new Uint8Array(size);

  payload[0] = (VERSION << 4) | flags;
  parts.reduce((offset, part) => {
    payload.set(part, offset);

    return offset + part.length;
  }, 1);

  return toBase64Url(payload);
};

/**
 * Unpacks a `v` value into the fields the plain query string would have
 * carried.
 *
 * Never throws and never guesses: a value that is truncated, that carries a
 * version or a host code this build does not know, or that is not base64url at
 * all, comes back as null. The caller then has no API and no process, which is
 * the same state as a link that arrived with neither — and lands on the same
 * "this voting link is incomplete" message.
 *
 * The fields are returned raw, exactly as the plain parameters arrive. Every
 * one of them still goes through the sanitizers in `params.js`; nothing here is
 * a substitute for that.
 *
 * @param {string} value - the `v` parameter.
 * @returns {Object|null} `{ api, process, locale, exit }`, or null.
 */
export const decodeLink = (value) => {
  if (typeof value !== "string" || value.trim() === "") {
    return null;
  }

  const bytes = fromBase64Url(value.trim());

  if (!bytes || bytes.length < 2) {
    return null;
  }

  const flags = bytes[0] & 0x0f;

  if (bytes[0] >> 4 !== VERSION || (flags & ~KNOWN_FLAGS) !== 0) {
    return null;
  }

  const decoder = new TextDecoder("utf-8", { fatal: true });
  let at = 1;

  /**
   * Takes the next `count` bytes, or throws when they are not there.
   *
   * @param {number} count - how many bytes.
   * @returns {Uint8Array} the slice.
   */
  const take = (count) => {
    if (count < 0 || at + count > bytes.length) {
      throw new RangeError("truncated");
    }

    const slice = bytes.subarray(at, at + count);

    at += count;

    return slice;
  };

  try {
    let api = null;

    if (flags & FLAG_INLINE_API) {
      api = decoder.decode(take(take(1)[0]));
    } else {
      api = API_HOSTS[take(1)[0]] || null;

      if (!api) {
        return null;
      }
    }

    const process = Array.from(take(PROCESS_ID_BYTES)).
      map((byte) => byte.toString(16).padStart(2, "0")).
      join("");

    const locale = flags & FLAG_LOCALE
      ? decoder.decode(take(take(1)[0]))
      : null;

    // Whatever is left is the exit path; when the flag is clear there must be
    // nothing left, or these are not the bytes this decoder was handed.
    const exit = flags & FLAG_EXIT
      ? decoder.decode(take(bytes.length - at))
      : null;

    if (at !== bytes.length) {
      return null;
    }

    return { api, process, locale, exit };
  } catch {
    return null;
  }
};

export default decodeLink;
