/* global jest */
/* eslint-disable camelcase -- mirrors the Rails i18n keys */
import { runOtp } from "src/decidim/elections/vocdoni/voter/booth_otp";

const panelMarkup = `
  <section data-panel>
    <form data-vocdoni-otp-form>
      <input data-vocdoni-otp-code>
      <p data-vocdoni-otp-feedback></p>
      <button type="button" data-vocdoni-otp-resend>resend</button>
    </form>
  </section>`;

const ctxFor = () => {
  document.body.innerHTML = panelMarkup;

  return {
    config: {
      i18n: {
        otp: { required: "Code required", resend: "Resend", resend_wait: "Wait %{seconds}" },
        status: { authenticating: "Auth…", sending_code: "Sending…" },
        errors: { unknown: "Unknown error" }
      }
    },
    showPanel: () => document.querySelector("[data-panel]")
  };
};

const submit = (code) => {
  document.querySelector("[data-vocdoni-otp-code]").value = code;
  document.querySelector("[data-vocdoni-otp-form]").dispatchEvent(new Event("submit", { cancelable: true }));
};

describe("runOtp()", () => {
  afterEach(() => {
    jest.useRealTimers();
  });

  it("resolves once the CSP accepts the code", async () => {
    const flow = { confirmOtp: jest.fn().mockResolvedValue(), resendOtp: jest.fn() };

    const done = runOtp(ctxFor(), flow);
    submit("123456");
    await done;

    expect(flow.confirmOtp).toHaveBeenCalledWith("123456");
  });

  it("drops its listeners once done, so a later sign-in confirms each code once", async () => {
    const ctx = ctxFor();
    const first = { confirmOtp: jest.fn().mockResolvedValue(), resendOtp: jest.fn() };
    const second = { confirmOtp: jest.fn().mockResolvedValue(), resendOtp: jest.fn() };

    const firstRun = runOtp(ctx, first);
    submit("111111");
    await firstRun;

    const secondRun = runOtp(ctx, second);
    submit("222222");
    await secondRun;

    expect(first.confirmOtp).toHaveBeenCalledTimes(1);
    expect(second.confirmOtp).toHaveBeenCalledTimes(1);
    expect(second.confirmOtp).toHaveBeenCalledWith("222222");
  });

  it("asks for a code before calling the CSP", () => {
    jest.useFakeTimers();
    const flow = { confirmOtp: jest.fn(), resendOtp: jest.fn() };

    runOtp(ctxFor(), flow);
    submit("  ");

    expect(flow.confirmOtp).not.toHaveBeenCalled();
    expect(document.querySelector("[data-vocdoni-otp-feedback]").textContent).toBe("Code required");
  });
});
