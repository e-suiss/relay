import { describe, expect, it } from "vitest";
import {
  createTranslator,
  en,
  format,
  placeholders,
  resolveLocale,
  tr,
} from "../src/i18n/index.js";

describe("X-32 localisation", () => {
  it("X-32 Turkish and English have the same keys", () => {
    expect(Object.keys(tr).sort()).toEqual(Object.keys(en).sort());
  });

  it("X-32 every text has the same placeholders in both languages", () => {
    for (const key of Object.keys(en) as (keyof typeof en)[]) {
      expect(placeholders(tr[key]), key).toEqual(placeholders(en[key]));
    }
  });

  it("X-32 no text is empty", () => {
    for (const [key, value] of [...Object.entries(en), ...Object.entries(tr)]) {
      expect(value.trim().length, key).toBeGreaterThan(0);
    }
  });

  it("X-32 picks Turkish for tr tags and English otherwise", () => {
    expect(resolveLocale("tr")).toBe("tr");
    expect(resolveLocale("tr-TR")).toBe("tr");
    expect(resolveLocale("en-US")).toBe("en");
    expect(resolveLocale("de")).toBe("en");
    expect(resolveLocale(undefined)).toBe("en");
  });

  it("X-32 fills placeholders and keeps unknown ones", () => {
    expect(format("{count} new", { count: 3 })).toBe("3 new");
    expect(format("{missing} stays")).toBe("{missing} stays");
  });

  it("X-32 overrides single texts", () => {
    const t = createTranslator("en", { "inbox.title": "Updates" });
    expect(t("inbox.title")).toBe("Updates");
    expect(t("inbox.delete")).toBe("Delete");
  });

  it("X-16 labels hide as delete and reports it as hidden", () => {
    expect(en["inbox.delete"]).toBe("Delete");
    expect(en["inbox.hidden"]).toMatch(/hidden/i);
    expect(tr["inbox.delete"]).toBe("Sil");
    expect(tr["inbox.hidden"]).toMatch(/gizlendi/i);
  });
});
