import { describe, expect, it } from "vitest";
import { en, type MessageKey } from "./en";
import { format, placeholders } from "./i18n";
import { tr } from "./tr";

describe("TP-30 console texts", () => {
  const keys = Object.keys(en) as MessageKey[];

  it("has a Turkish text for every English key and no extra key", () => {
    expect(Object.keys(tr).sort()).toEqual([...keys].sort());
  });

  it("uses the same placeholders in both languages", () => {
    for (const key of keys) {
      expect(placeholders(tr[key]), key).toEqual(placeholders(en[key]));
    }
  });

  it("leaves no text empty", () => {
    for (const key of keys) {
      expect(en[key].trim(), key).not.toBe("");
      expect(tr[key].trim(), key).not.toBe("");
    }
  });

  it("fills placeholders and keeps unknown ones visible", () => {
    expect(format("{a} and {b}", { a: 1 })).toBe("1 and {b}");
  });
});
