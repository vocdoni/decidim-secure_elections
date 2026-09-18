import { CHANNELS, channelsFor, contactBody, defaultChannel, offersChannelChoice, requiresOtp } from "src/decidim/elections/vocdoni/voter/two_fa";

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

  it("drops a channel the voting page cannot deliver, instead of showing an empty field", () => {
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

describe("offersChannelChoice", () => {
  it("only asks the voter when there is genuinely something to choose", () => {
    expect(offersChannelChoice([])).toBe(false);
    expect(offersChannelChoice(["email"])).toBe(false);
    expect(offersChannelChoice(["phone"])).toBe(false);
    expect(offersChannelChoice(["email", "phone"])).toBe(true);
  });
});

describe("defaultChannel", () => {
  it("is the single channel on offer", () => {
    expect(defaultChannel(["email"])).toBe("email");
    expect(defaultChannel(["phone"])).toBe("phone");
  });

  it("is null when there is nothing to send, or when the voter must choose", () => {
    expect(defaultChannel([])).toBeNull();
    expect(defaultChannel(["email", "phone"])).toBeNull();
  });
});

describe("contactBody", () => {
  it("keys the contact by its channel, which is how the CSP reads it", () => {
    expect(contactBody("email", "carol@example.org")).toEqual({ email: "carol@example.org" });
    expect(contactBody("phone", "+34600000000")).toEqual({ phone: "+34600000000" });
  });

  it("trims, so a pasted address does not become a participant-not-found", () => {
    expect(contactBody("email", "  carol@example.org \n")).toEqual({ email: "carol@example.org" });
  });

  it("yields nothing rather than an empty key the CSP would reject", () => {
    expect(contactBody("email", "")).toEqual({});
    expect(contactBody("email", "   ")).toEqual({});
    expect(contactBody("email", null)).toEqual({});
    expect(contactBody(null, "carol@example.org")).toEqual({});
    expect(contactBody("telegram", "@carol")).toEqual({});
  });
});
