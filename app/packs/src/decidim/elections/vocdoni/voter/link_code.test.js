import { API_HOSTS, decodeLink, encodeLink } from "src/decidim/elections/vocdoni/voter/link_code";

const PROCESS_ID = "6a6899181400d83458fde280";
const STAGING = "https://saas-api-stg.vocdoni.net";
const EXIT = "/en/processes/petiquipeti2/f/61/elections/20";

/**
 * The exact values Decidim mints, so that the Ruby encoder and this decoder
 * cannot drift apart without one of the two suites failing. The same three
 * strings are asserted in `spec/services/decidim/elections/vocdoni/voting_page_url_spec.rb`
 * — they are the only thing tying the two implementations together.
 */
const FIXTURES = {
  minimal: "EAJqaJkYFADYNFj94oA",
  withLocale: "EgJqaJkYFADYNFj94oACZW4",
  full: "FgJqaJkYFADYNFj94oACZW4vZW4vcHJvY2Vzc2VzL3BldGlxdWlwZXRpMi9mLzYxL2VsZWN0aW9ucy8yMA"
};

/**
 * A `v` value built from raw bytes, for the malformed cases a working encoder
 * cannot produce.
 *
 * @param {...number} bytes - the payload.
 * @returns {string} the base64url value.
 */
const packed = (...bytes) => btoa(String.fromCharCode(...bytes)).
  replace(/\+/g, "-").replace(/\//g, "_").replace(/[=]+$/, "");

/** Twelve bytes standing in for a process id. */
const SOME_PROCESS = Array(12).fill(0x11);

describe("the packed link", () => {
  it("round-trips the whole payload", () => {
    const fields = { api: STAGING, process: PROCESS_ID, locale: "en", exit: EXIT };

    expect(decodeLink(encodeLink(fields))).toEqual(fields);
  });

  // The common case: the API is a known host, the process is 12 packed bytes,
  // and there is nothing else to say. Both optional fields are absent from the
  // payload rather than present and empty.
  it("round-trips a payload with no locale and no exit", () => {
    expect(decodeLink(encodeLink({ api: STAGING, process: PROCESS_ID }))).toEqual({
      api: STAGING,
      process: PROCESS_ID,
      locale: null,
      exit: null
    });
  });

  it("agrees byte for byte with the encoder Decidim uses", () => {
    expect(encodeLink({ api: STAGING, process: PROCESS_ID })).toBe(FIXTURES.minimal);
    expect(encodeLink({ api: STAGING, process: PROCESS_ID, locale: "en" })).toBe(FIXTURES.withLocale);
    expect(encodeLink({ api: STAGING, process: PROCESS_ID, locale: "en", exit: EXIT })).toBe(FIXTURES.full);
  });

  it("decodes what that encoder wrote", () => {
    expect(decodeLink(FIXTURES.full)).toEqual({
      api: STAGING,
      process: PROCESS_ID,
      locale: "en",
      exit: EXIT
    });
  });

  // The whole point of the host table: the base URL is the longest field and
  // identical for every election on an installation.
  it("spends one byte on a known API host, so the shortest link is 19 characters", () => {
    expect(Object.values(API_HOSTS)).toContain(STAGING);
    expect(encodeLink({ api: STAGING, process: PROCESS_ID })).toHaveLength(19);
  });

  it("carries an unknown API host inline rather than refusing the link", () => {
    const api = "https://vocdoni.example.org/api";

    expect(decodeLink(encodeLink({ api, process: PROCESS_ID, locale: "en" }))).toEqual({
      api,
      process: PROCESS_ID,
      locale: "en",
      exit: null
    });
  });

  it("is url-safe and unpadded, so it never needs escaping", () => {
    const value = encodeLink({ api: "https://vocdoni.example.org/api", process: PROCESS_ID, locale: "en" });

    expect(value).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(encodeURIComponent(value)).toBe(value);
  });

  it("survives a multi-byte exit path", () => {
    const exit = "/ca/processes/eleccions-munchen-ü/f/1/elections/2";

    expect(decodeLink(encodeLink({ api: STAGING, process: PROCESS_ID, exit }))).toEqual({
      api: STAGING,
      process: PROCESS_ID,
      locale: null,
      exit
    });
  });

  it("refuses a payload it cannot build", () => {
    expect(encodeLink({ api: STAGING, process: "not-a-process" })).toBeNull();
    expect(encodeLink({ api: STAGING })).toBeNull();
    expect(encodeLink()).toBeNull();
  });
});

// Nothing here may throw: every one of these has to end on the voting page's
// "this voting link is incomplete" message, which is what `null` produces.
describe("a link that will not decode", () => {
  it("refuses a truncated value", () => {
    [FIXTURES.full.slice(0, 4), FIXTURES.full.slice(0, 12), FIXTURES.minimal.slice(0, 10), "E", ""].
      forEach((value) => expect(decodeLink(value)).toBeNull());
  });

  it("refuses anything that is not base64url", () => {
    ["not base64!", "AAAA==AAAA", "%%%", "../../etc/passwd", "   ", null, 42].
      forEach((value) => expect(decodeLink(value)).toBeNull());
  });

  // A version this build does not know means bytes it would misread. Guessing
  // at them is how a voter ends up authenticating against the wrong API.
  it("refuses a version it does not know", () => {
    expect(decodeLink(packed(0x20, 2, ...SOME_PROCESS))).toBeNull();
  });

  it("refuses a flag it does not know", () => {
    expect(decodeLink(packed(0x18, 2, ...SOME_PROCESS))).toBeNull();
  });

  it("refuses an API host code that is not in the table", () => {
    expect(decodeLink(packed(0x10, 0xff, ...SOME_PROCESS))).toBeNull();
  });

  // Trailing bytes with no flag to claim them mean this is not the message the
  // decoder thinks it is reading.
  it("refuses trailing bytes nothing accounts for", () => {
    expect(decodeLink(packed(0x10, 2, ...SOME_PROCESS, 0x41, 0x41))).toBeNull();
  });
});
