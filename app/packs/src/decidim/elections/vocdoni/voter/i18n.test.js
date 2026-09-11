/* global jest */

import { loadTranslations, localeCandidates, pickLocale } from "src/decidim/elections/vocdoni/voter/i18n";

const BASE = "https://decidim.example.org/vocdoni/locales/";

/**
 * A `fetch` that answers from a map of URL to JSON body, and 404s otherwise.
 *
 * @param {Object} documents - `{ [url]: body }`.
 * @returns {Function} the fake fetch.
 */
const fakeFetch = (documents) => jest.fn((url) => Promise.resolve(url in documents
  ? { ok: true, json: () => Promise.resolve(documents[url]) }
  : { ok: false, status: 404 }));

describe("localeCandidates", () => {
  it("puts the requested locale first, then the browser's, then English", () => {
    expect(localeCandidates("ca", ["es-ES", "en-GB"])).toEqual(["ca", "es-es", "es", "en-gb", "en"]);
  });

  it("expands a region tag so a base-language file can serve it", () => {
    expect(localeCandidates("pt-BR", [])).toEqual(["pt-br", "pt", "en"]);
  });

  it("ignores a bogus tag rather than fetching it", () => {
    expect(localeCandidates("../secrets", ["fr"])).toEqual(["fr", "en"]);
  });
});

describe("pickLocale", () => {
  it("matches case-insensitively and answers with the file's own name", () => {
    expect(pickLocale(["en", "pt-BR"], ["pt-br", "en"])).toBe("pt-BR");
  });

  it("answers null when nothing matches, so the caller can fall back", () => {
    expect(pickLocale(["en"], ["ca"])).toBeNull();
  });
});

describe("loadTranslations", () => {
  it("reads the index once, then exactly one translation file", async () => {
    const fetchImpl = fakeFetch({
      [`${BASE}index.json`]: { default: "en", locales: ["en", "ca"] },
      [`${BASE}ca.json`]: { exit: "Surt" }
    });

    const result = await loadTranslations({ baseUrl: BASE, requested: "ca", languages: ["en"], fetchImpl });

    expect(result).toEqual({ locale: "ca", messages: { exit: "Surt" } });
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("falls back to English when the requested locale is not shipped", async () => {
    const fetchImpl = fakeFetch({
      [`${BASE}index.json`]: { default: "en", locales: ["en"] },
      [`${BASE}en.json`]: { exit: "Leave the voting page" }
    });

    expect((await loadTranslations({ baseUrl: BASE, requested: "ca", languages: ["ca-ES"], fetchImpl })).locale).toBe("en");
  });

  it("negotiates from the browser when the link named no locale", async () => {
    const fetchImpl = fakeFetch({
      [`${BASE}index.json`]: { default: "en", locales: ["en", "ca"] },
      [`${BASE}ca.json`]: { exit: "Surt" }
    });

    expect((await loadTranslations({ baseUrl: BASE, languages: ["ca-ES", "en"], fetchImpl })).locale).toBe("ca");
  });

  // The caller renders the static, English "could not start" block: a voting page with
  // no vocabulary must not paint half a form with undefined labels.
  it("rejects when the translations cannot be fetched at all", async () => {
    await expect(loadTranslations({ baseUrl: BASE, fetchImpl: fakeFetch({}) })).rejects.toThrow();
  });
});
