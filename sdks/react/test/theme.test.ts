import { describe, expect, it } from "vitest";
import {
  contrastRatio,
  darkTheme,
  lightTheme,
  readableTextOn,
  resolveBrand,
  themeVariables,
} from "../src/theme.js";

describe("X-32 theming and contrast", () => {
  for (const [name, theme] of [
    ["light", lightTheme],
    ["dark", darkTheme],
  ] as const) {
    it(`X-32 the ${name} theme meets WCAG 2.2 AA contrast`, () => {
      for (const background of [theme.background, theme.surface]) {
        expect(contrastRatio(theme.text, background)).toBeGreaterThanOrEqual(4.5);
        expect(contrastRatio(theme.mutedText, background)).toBeGreaterThanOrEqual(4.5);
        expect(contrastRatio(theme.danger, background)).toBeGreaterThanOrEqual(4.5);
        expect(contrastRatio(theme.success, background)).toBeGreaterThanOrEqual(4.5);
        expect(contrastRatio(theme.warning, background)).toBeGreaterThanOrEqual(4.5);
        expect(contrastRatio(theme.accent, background)).toBeGreaterThanOrEqual(4.5);
        expect(contrastRatio(theme.border, background)).toBeGreaterThanOrEqual(3);
      }
      expect(contrastRatio(theme.accentText, theme.accent)).toBeGreaterThanOrEqual(4.5);
      expect(contrastRatio(theme.background, theme.danger)).toBeGreaterThanOrEqual(4.5);
    });
  }

  it("X-32 picks readable text on a brand colour", () => {
    expect(readableTextOn("#0b5c3b")).toBe("#ffffff");
    expect(readableTextOn("#ffd84d")).toBe("#000000");
  });

  it("X-32 a sub-tenant brand wins over the tenant brand", () => {
    const brand = resolveBrand(
      {
        name: "Tenant",
        logoUrl: "https://tenant.example/logo.svg",
        theme: { accent: "#123456", radius: "4px" },
      },
      { name: "Sub brand", theme: { accent: "#0b5c3b" } },
    );
    expect(brand.name).toBe("Sub brand");
    expect(brand.logoUrl).toBe("https://tenant.example/logo.svg");
    expect(brand.theme).toEqual({ accent: "#0b5c3b", radius: "4px" });
  });

  it("X-32 maps a theme to custom properties with readable accent text", () => {
    const variables = themeVariables("light", { accent: "#ffd84d" });
    expect(variables["--relay-color-accent"]).toBe("#ffd84d");
    expect(variables["--relay-color-accent-text"]).toBe("#000000");
    expect(variables["--relay-color-text"]).toBe(lightTheme.text);
  });
});
