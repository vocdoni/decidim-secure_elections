import { CHANNELS, channelsFor, requiresOtp } from "src/decidim/elections/vocdoni/voter/two_fa";

// The three censuses ARCHITECTURE §4c can produce, plus the shapes a process read
// can realistically hand us for an auth-only one.
describe("channelsFor", () => {
  it("maps the three configured censuses onto their channels", () => {
    expect(channelsFor([])).toEqual([]);
    expect(channelsFor(["email"])).toEqual(["email"]);
    expect(channelsFor(["phone"])).toEqual(["phone"]);
    expect(channelsFor(["email", "phone"])).toEqual(["email", "phone"]);
  });

  it("normalises the order, so the UI does not depend on the API's", () => {
    expect(channelsFor(["phone", "email"])).toEqual(CHANNELS);
  });

  it("treats an absent census as auth-only rather than throwing", () => {
    expect(channelsFor(null)).toEqual([]);
    expect(channelsFor()).toEqual([]);
    expect(channelsFor("email")).toEqual([]);
  });

  it("drops a channel the booth cannot deliver, instead of showing an empty field", () => {
    expect(channelsFor(["email", "telegram"])).toEqual(["email"]);
    expect(channelsFor(["totp"])).toEqual([]);
  });
});

describe("requiresOtp", () => {
  it("is false only for a census with no usable two-factor field", () => {
    expect(requiresOtp([])).toBe(false);
    expect(requiresOtp(null)).toBe(false);
    expect(requiresOtp(["totp"])).toBe(false);
    expect(requiresOtp(["email"])).toBe(true);
    expect(requiresOtp(["phone"])).toBe(true);
    expect(requiresOtp(["email", "phone"])).toBe(true);
  });
});
