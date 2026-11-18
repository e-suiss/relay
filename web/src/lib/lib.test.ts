import { describe, expect, it } from "vitest";
import { durationSeconds, humanDuration, isDuration } from "./duration";
import {
  freshName,
  icuEscape,
  icuMessage,
  pluralCategories,
  pluralSnippet,
  samplePlural,
} from "./plural";
import { sandboxSource } from "./sandbox";
import { chooseEncoding, measureSms, segments, transliterate } from "./sms";
import { htmlToText, smsDraftFromEmail } from "./text";

describe("TP-18 SMS measure", () => {
  it("picks GSM7, the Turkish single shift or UCS2 like the server", () => {
    expect(chooseEncoding("Order shipped")).toBe("GSM7");
    expect(chooseEncoding("Çok güzel")).toBe("GSM7");
    expect(chooseEncoding("Siparişiniz yolda")).toBe("GSM7_TR");
    expect(chooseEncoding("Hello 👋")).toBe("UCS2");
  });

  it("splits long text into concatenated segments without splitting escapes", () => {
    expect(segments("a".repeat(160), "GSM7")).toHaveLength(1);
    expect(segments("a".repeat(161), "GSM7")).toHaveLength(2);
    expect(segments("ş".repeat(77), "GSM7_TR")).toHaveLength(1);
    expect(segments("ş".repeat(78), "GSM7_TR")).toHaveLength(2);
    const parts = segments(`${"a".repeat(151)}€${"b".repeat(10)}`, "GSM7");
    expect(parts[0]).toBe("a".repeat(151));
    expect(parts[1]).toBe(`€${"b".repeat(10)}`);
    expect(segments("", "GSM7")).toEqual([]);
    expect(measureSms("x".repeat(71) + "👋").segments).toHaveLength(2);
  });
});

describe("CH-49 transliteration preview", () => {
  it("replaces only letters the default alphabet cannot carry", () => {
    expect(transliterate("Şüphe ığdır Çay")).toBe("Süphe igdir Çay");
    expect(chooseEncoding(transliterate("Siparişiniz yolda"))).toBe("GSM7");
  });
});

describe("AG-17 durations", () => {
  it("reads ISO 8601 durations of weeks to seconds", () => {
    expect(isDuration("PT2H")).toBe(true);
    expect(isDuration("P1M")).toBe(false);
    expect(isDuration("P")).toBe(false);
    expect(durationSeconds("P1W1DT1H1M1S")).toBe(604_800 + 86_400 + 3_661);
    expect(durationSeconds("2h")).toBeNull();
    expect(humanDuration(5400, "en")).toBe("1h 30m");
  });
});

describe("TP-22 plain text from HTML", () => {
  it("keeps paragraphs, list items, links and template tags", () => {
    const text = htmlToText(
      '<h1>Hi {{ data.name }}</h1><p>Your order <b>shipped</b>.</p><ul><li>One</li><li>Two</li></ul><a href="https://x.test/o">Track</a><script>bad()</script>',
    );
    expect(text).toBe(
      "Hi {{ data.name }}\n\nYour order shipped.\n\n- One\n- Two\n\nTrack (https://x.test/o)",
    );
  });

  it("reads MJML bodies", () => {
    expect(
      htmlToText(
        "<mjml><mj-head><mj-title>T</mj-title></mj-head><mj-body><mj-section><mj-column><mj-text>Hello</mj-text></mj-column></mj-section></mj-body></mjml>",
      ),
    ).toBe("Hello");
  });
});

describe("TP-10 SMS draft from e-mail", () => {
  it("takes the subject and the first paragraph, as a draft", () => {
    expect(
      smsDraftFromEmail({
        subject: "Order shipped",
        text: "Your parcel is on its way.\n\nThanks for shopping.",
        html: "",
      }),
    ).toBe("Order shipped\nYour parcel is on its way.");
    expect(
      smsDraftFromEmail({ subject: "", text: "", html: "<p>From HTML</p>" }),
    ).toBe("From HTML");
  });
});

describe("TP-27 plural fields", () => {
  it("shows the language's CLDR categories", () => {
    expect(pluralCategories("tr")).toEqual(["one", "other"]);
    expect(pluralCategories("ar")).toEqual([
      "zero",
      "one",
      "two",
      "few",
      "many",
      "other",
    ]);
  });

  it("generates the ICU message behind and keeps Liquid as written", () => {
    const value = {
      variable: "data.count",
      zero: "Mesaj yok",
      forms: { one: "# mesaj", other: "# mesaj, {{ data.name }}'s" },
    };
    expect(icuEscape("a {b} it's")).toBe("a '{'b'}' it''s");
    expect(icuMessage(value, "tr")).toBe(
      "{n, plural, =0 {Mesaj yok} one {# mesaj} other {# mesaj, {{ data.name }}''s}}",
    );
    expect(pluralSnippet("plural_1", value, "tr")).toBe(
      "{% capture plural_1 %}{n, plural, =0 {Mesaj yok} one {# mesaj} other {# mesaj, {{ data.name }}''s}}{% endcapture %}{{ plural_1 | icu: n: data.count }}",
    );
    expect(freshName("x plural_1 y")).toBe("plural_2");
    expect(samplePlural(value, 0, "tr")).toBe("Mesaj yok");
    expect(samplePlural(value, 3, "en")).toContain("3 mesaj");
  });
});

describe("TP-39 sandboxed preview source", () => {
  it("loads only https links on another origin", () => {
    const own = "https://relay.example";
    expect(sandboxSource("https://preview.relay.example/sandbox/x", own)).toBe(
      "https://preview.relay.example/sandbox/x",
    );
    expect(sandboxSource("https://relay.example/sandbox/x", own)).toBeNull();
    expect(sandboxSource("http://preview.relay.example/x", own)).toBeNull();
    expect(sandboxSource("javascript:alert(1)", own)).toBeNull();
    expect(sandboxSource(null, own)).toBeNull();
  });
});
