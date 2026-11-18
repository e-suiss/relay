import { describe, expect, it } from "vitest";
import { parseLookup } from "./lookup";

describe("X-12 lookup input", () => {
  it("reads an email address, a phone number or a recipient identifier", () => {
    expect(parseLookup(" Seed@Seed.Relay.Test ")).toEqual({
      kind: "email",
      value: "seed@seed.relay.test",
    });
    expect(parseLookup("+90 532 123 45 67")).toEqual({
      kind: "phone",
      value: "+905321234567",
    });
    expect(parseLookup("seed_no_consent")).toEqual({
      kind: "id",
      value: "seed_no_consent",
    });
    expect(parseLookup("   ")).toBeNull();
  });
});
