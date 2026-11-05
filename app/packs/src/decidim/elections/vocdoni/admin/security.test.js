/**
 * The Security tab's progressive enhancement against the markup the server
 * renders (`admin/security/_choice` and `_two_factor`), reduced to the
 * selectors `security.js` reads. There is no summary element any more: the
 * toggles must work without it.
 */
import setupSecurity from "src/decidim/elections/vocdoni/admin/security";

// What the server renders for each saved choice.
const SAVED = {
  simple: { simple: "checked", secure: "", block: "hidden disabled" },
  secure: { simple: "", secure: "checked", block: "" }
};

const render = (saved) => {
  const state = SAVED[saved];
  document.body.innerHTML = `
    <fieldset id="js-security-choice">
      <div data-security-choice-card="simple">
        <input type="radio" name="security[enable_vocdoni]" value="false" data-security-choice="simple" ${state.simple}>
        <label>Simple vote</label>
        <ul><li data-testid="simple-point">Ballots are stored in this platform's database.</li></ul>
      </div>
      <div data-security-choice-card="secure">
        <input type="radio" name="security[enable_vocdoni]" value="true" data-security-choice="secure" ${state.secure}>
        <label>Secret, verifiable vote</label>
        <ul><li data-testid="secure-point">Nobody can link a ballot to a voter.</li></ul>
      </div>
    </fieldset>
    <fieldset id="js-security-two-factor" ${state.block}>
      <input type="checkbox" name="security[email]" data-security-code>
    </fieldset>
  `;
  setupSecurity();
};

const card = (value) => document.querySelector(`[data-security-choice-card="${value}"]`);
const twoFactor = () => document.getElementById("js-security-two-factor");

describe("Security tab", () => {
  afterEach(() => {
    document.body.innerHTML = "";
  });

  it("shows and enables the one-time code block when the secret vote is picked", () => {
    render("simple");

    document.querySelector("[data-testid='secure-point']").click();

    expect(card("secure").classList.contains("is-selected")).toBe(true);
    expect(card("simple").classList.contains("is-selected")).toBe(false);
    expect(twoFactor().hidden).toBe(false);
    expect(twoFactor().disabled).toBe(false);
  });

  it("hides and disables the one-time code block when the simple vote is picked", () => {
    render("secure");

    document.querySelector("[data-testid='simple-point']").click();

    expect(card("simple").classList.contains("is-selected")).toBe(true);
    expect(twoFactor().hidden).toBe(true);
    expect(twoFactor().disabled).toBe(true);
  });

  it("starts in step with a radio restored by the browser", () => {
    render("simple");
    document.querySelector("[data-security-choice='secure']").checked = true;

    setupSecurity();

    expect(twoFactor().hidden).toBe(false);
    expect(card("secure").classList.contains("is-selected")).toBe(true);
  });

  it("does nothing on a page without the Security form", () => {
    document.body.innerHTML = "<p>Dashboard</p>";

    expect(() => setupSecurity()).not.toThrow();
  });
});
