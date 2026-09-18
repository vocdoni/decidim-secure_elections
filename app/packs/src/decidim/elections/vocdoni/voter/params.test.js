import { isUsable, readParams, sanitizeApiUrl, sanitizeExitUrl, sanitizeLocale, sanitizeProcessId } from "src/decidim/elections/vocdoni/voter/params";
import { encodeLink } from "src/decidim/elections/vocdoni/voter/link_code";

const PROCESS_ID = "6885f0c2c1a4e2f0b1d33a01";

const location = (search) => new URL(`https://decidim.example.org/vocdoni/vote.html${search}`);

describe("the API base URL", () => {
  it("accepts a base this build knows and drops the trailing slash", () => {
    expect(sanitizeApiUrl("https://saas-api.vocdoni.net/")).toBe("https://saas-api.vocdoni.net");
  });

  it("keeps a path prefix, because an API can be mounted under one", () => {
    expect(sanitizeApiUrl("https://decidim.example.org/vocdoni/api/", location(""))).
      toBe("https://decidim.example.org/vocdoni/api");
  });

  it("drops a query and a fragment, which would corrupt every request path", () => {
    expect(sanitizeApiUrl("https://decidim.example.org/api?key=leak#x", location(""))).
      toBe("https://decidim.example.org/api");
  });

  // A relative value would resolve against this Decidim installation, and the
  // voting page would then post census credentials to it.
  it("refuses anything that is not an absolute https URL", () => {
    // eslint-disable-next-line no-script-url
    ["/api", "api.example.org", "javascript:alert(1)", "data:text/html,x", "", null].
      forEach((value) => expect(sanitizeApiUrl(value, location(""))).toBeNull());
  });

  // The page is served from the installation's own domain, so a link naming a
  // foreign API is a credential collector wearing a trusted address.
  it("refuses an origin that is neither a known base, this origin, nor loopback", () => {
    ["https://attacker.example", "https://saas-api.vocdoni.net.attacker.example", "https://evil.test/api"].
      forEach((value) => expect(sanitizeApiUrl(value, location(""))).toBeNull());
  });

  it("refuses a known base reached over plain HTTP", () => {
    expect(sanitizeApiUrl("http://saas-api.vocdoni.net", location(""))).toBeNull();
  });

  it("allows a local API over plain HTTP, so the flow can be developed", () => {
    expect(sanitizeApiUrl("http://localhost:8080/api", location(""))).toBe("http://localhost:8080/api");
  });

  // With no location to compare against — the way the sanitizer is called from
  // a unit test or a tool — only the bases this build knows are allowed.
  it("falls back to the known bases when it has no origin of its own", () => {
    expect(sanitizeApiUrl("https://saas-api-stg.vocdoni.net")).toBe("https://saas-api-stg.vocdoni.net");
    expect(sanitizeApiUrl("https://decidim.example.org/api")).toBeNull();
  });
});

describe("the process id", () => {
  it("accepts a Mongo ObjectID and normalizes its case", () => {
    expect(sanitizeProcessId(` ${PROCESS_ID.toUpperCase()} `)).toBe(PROCESS_ID);
  });

  it("refuses anything else", () => {
    ["", "abc", `${PROCESS_ID}0`, "../../etc/passwd", null].
      forEach((value) => expect(sanitizeProcessId(value)).toBeNull());
  });
});

describe("the locale", () => {
  it("accepts a language tag and normalizes the separator", () => {
    expect(sanitizeLocale("pt_BR")).toBe("pt-BR");
  });

  // The locale is interpolated into a fetch path, so it may never carry a slash.
  it("refuses anything that could escape the locales directory", () => {
    ["../../secrets", "en/../..", "e", "", null].
      forEach((value) => expect(sanitizeLocale(value)).toBeNull());
  });
});

describe("the exit URL", () => {
  it("keeps a same-origin path", () => {
    expect(sanitizeExitUrl("/processes/demo/f/1/elections/2", location(""))).
      toBe("/processes/demo/f/1/elections/2");
  });

  it("reduces a same-origin absolute URL to its path", () => {
    expect(sanitizeExitUrl("https://decidim.example.org/elections/2?x=1", location(""))).
      toBe("/elections/2?x=1");
  });

  // Otherwise the voting page becomes a redirector, one click after somebody typed
  // their census credentials into it.
  it("refuses any other origin, including a protocol-relative one", () => {
    // eslint-disable-next-line no-script-url
    ["https://evil.example/steal", "//evil.example/steal", "javascript:alert(1)"].
      forEach((value) => expect(sanitizeExitUrl(value, location(""))).toBeNull());
  });
});

describe("readParams", () => {
  // Every link Decidim mints now says `?v=`, so this is the ordinary path.
  it("reads a packed link", () => {
    const params = readParams(location(`?v=${encodeLink({
      api: "https://saas-api.vocdoni.net",
      process: PROCESS_ID,
      locale: "ca",
      exit: "/back"
    })}`));

    expect(params).toEqual({
      apiUrl: "https://saas-api.vocdoni.net",
      processId: PROCESS_ID,
      locale: "ca",
      exitUrl: "/back"
    });
    expect(isUsable(params)).toBe(true);
  });

  // Packing is an abbreviation, not a bypass: the decoded values go through
  // exactly the same sanitizers as the plain ones, so a packed link cannot say
  // anything a plain one could not.
  it("still refuses a cross-origin exit and a bogus locale inside a packed link", () => {
    const params = readParams(location(`?v=${encodeLink({
      api: "https://saas-api.vocdoni.net",
      process: PROCESS_ID,
      locale: "../../secrets",
      exit: "https://evil.example/steal"
    })}`));

    expect(params.locale).toBeNull();
    expect(params.exitUrl).toBeNull();
    expect(isUsable(params)).toBe(true);
  });

  it("refuses a packed link carrying an API that is not an absolute https URL", () => {
    const params = readParams(location(`?v=${encodeLink({ api: "/api", process: PROCESS_ID })}`));

    expect(isUsable(params)).toBe(false);
  });

  // The packed form can carry an arbitrary API base inline. That is what makes
  // it the more dangerous half of this attack: the origin is not visible in the
  // address bar at all, only the trusted Decidim domain is. It goes through the
  // same origin check as the plain parameter, so it buys an attacker nothing.
  it("refuses a packed link carrying a foreign API origin", () => {
    const params = readParams(location(`?v=${encodeLink({
      api: "https://attacker.example",
      process: PROCESS_ID
    })}`));

    expect(params.apiUrl).toBeNull();
    expect(isUsable(params)).toBe(false);
  });

  // A hostile or truncated `v` lands on the same "this voting link is
  // incomplete" message as a link that carried nothing at all — never a throw.
  it("treats a value it cannot decode as a link that says nothing", () => {
    ["", "not base64!", "EAJqaJkY", "../../etc/passwd", "AAAAAAAAAAAAAAAAAAAAAAAA"].forEach((value) => {
      const params = readParams(location(`?v=${encodeURIComponent(value)}`));

      expect(params).toEqual({ apiUrl: null, processId: null, locale: null, exitUrl: null });
      expect(isUsable(params)).toBe(false);
    });
  });

  // A link carrying both has been tampered with; `v` wins and nothing falls
  // back to the plain parameters beside it.
  it("does not fall back to the plain parameters when a packed one is present", () => {
    const params = readParams(location(`?v=nonsense&api=https://saas-api.vocdoni.net&process=${PROCESS_ID}`));

    expect(isUsable(params)).toBe(false);
  });

  // The form every link minted before the packed one takes. Those links are in
  // inboxes and on printed sheets, so they have to keep working.
  it("reads the whole plain query string", () => {
    const params = readParams(location(`?api=https://saas-api.vocdoni.net&process=${PROCESS_ID}&locale=ca&exit=/back`));

    expect(params).toEqual({
      apiUrl: "https://saas-api.vocdoni.net",
      processId: PROCESS_ID,
      locale: "ca",
      exitUrl: "/back"
    });
    expect(isUsable(params)).toBe(true);
  });

  it("is unusable without both an API and a process", () => {
    expect(isUsable(readParams(location("?api=https://saas-api.vocdoni.net")))).toBe(false);
    expect(isUsable(readParams(location(`?process=${PROCESS_ID}`)))).toBe(false);
    expect(isUsable(readParams(location("")))).toBe(false);
  });

  it("is still usable without a locale or an exit, which are conveniences", () => {
    const params = readParams(location(`?api=https://saas-api.vocdoni.net&process=${PROCESS_ID}`));

    expect(isUsable(params)).toBe(true);
    expect(params.locale).toBeNull();
    expect(params.exitUrl).toBeNull();
  });
});
