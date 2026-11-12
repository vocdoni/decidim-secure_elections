/* global jest */

import { notifyVoteCast } from "src/decidim/elections/vocdoni/voter/cast_notification";

const docWithToken = (content) => ({
  querySelector: (selector) => (selector === "meta[name='csrf-token']" && content
    ? { content }
    : null)
});

describe("notifyVoteCast", () => {
  it("POSTs to the URL with the CSRF token and no body", async () => {
    const fetchFn = jest.fn().mockResolvedValue({ ok: true });

    await expect(notifyVoteCast("/elections/1/vocdoni_cast_notification", { fetchFn, doc: docWithToken("tok") })).resolves.toBe(true);

    expect(fetchFn).toHaveBeenCalledTimes(1);
    const [url, options] = fetchFn.mock.calls[0];
    expect(url).toBe("/elections/1/vocdoni_cast_notification");
    expect(options.method).toBe("POST");
    expect(options.credentials).toBe("same-origin");
    expect(options.headers["X-CSRF-Token"]).toBe("tok");
    expect(options.body).toBeUndefined();
  });

  it("does nothing without a URL", async () => {
    const fetchFn = jest.fn();

    await expect(notifyVoteCast(null, { fetchFn, doc: docWithToken("tok") })).resolves.toBe(false);
    expect(fetchFn).not.toHaveBeenCalled();
  });

  it("swallows network errors and rejected responses", async () => {
    const failing = jest.fn().mockRejectedValue(new Error("offline"));
    const throwing = jest.fn(() => {
      throw new Error("sync throw");
    });
    const limited = jest.fn().mockResolvedValue({ ok: false, status: 429 });

    await expect(notifyVoteCast("/x", { fetchFn: failing, doc: docWithToken(null) })).resolves.toBe(false);
    await expect(notifyVoteCast("/x", { fetchFn: throwing, doc: docWithToken(null) })).resolves.toBe(false);
    await expect(notifyVoteCast("/x", { fetchFn: limited, doc: docWithToken(null) })).resolves.toBe(false);
  });

  it("omits the CSRF header when the page has no token", async () => {
    const fetchFn = jest.fn().mockResolvedValue({ ok: true });

    await notifyVoteCast("/x", { fetchFn, doc: docWithToken(null) });

    expect(fetchFn.mock.calls[0][1].headers).not.toHaveProperty("X-CSRF-Token");
  });
});
