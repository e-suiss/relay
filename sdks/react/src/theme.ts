/** Colour and shape tokens of the components; each maps to a `--relay-*` CSS custom property. */
export interface RelayTheme {
  readonly background?: string;
  readonly surface?: string;
  readonly text?: string;
  readonly mutedText?: string;
  readonly border?: string;
  readonly accent?: string;
  readonly accentText?: string;
  readonly danger?: string;
  readonly success?: string;
  readonly warning?: string;
  readonly focus?: string;
  readonly radius?: string;
  readonly fontFamily?: string;
  readonly fontSize?: string;
}

/** A brand: its name and logo shown in the components and its theme for each colour scheme. */
export interface RelayBrand {
  readonly name?: string;
  readonly logoUrl?: string;
  /** Tokens over the light theme. */
  readonly theme?: RelayTheme;
  /** Tokens over the dark theme; a light theme's brand colours often lack contrast on a dark background. */
  readonly darkTheme?: RelayTheme;
}

/** The colour scheme: light, dark or the user's system setting. */
export type ColorScheme = "light" | "dark" | "auto";

/** The default light theme; every text colour meets WCAG 2.2 AA contrast on its background. */
export const lightTheme: Required<RelayTheme> = {
  background: "#ffffff",
  surface: "#f5f6f8",
  text: "#1b1f24",
  mutedText: "#4b5563",
  border: "#7b8494",
  accent: "#1f4fd1",
  accentText: "#ffffff",
  danger: "#b42318",
  success: "#146c2e",
  warning: "#8a4b00",
  focus: "#1f4fd1",
  radius: "8px",
  fontFamily: "system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif",
  fontSize: "16px",
};

/** The default dark theme; every text colour meets WCAG 2.2 AA contrast on its background. */
export const darkTheme: Required<RelayTheme> = {
  background: "#111418",
  surface: "#1c2027",
  text: "#f1f3f5",
  mutedText: "#b8c0cc",
  border: "#7c8696",
  accent: "#8fb0ff",
  accentText: "#0b1220",
  danger: "#ff9b8f",
  success: "#7ad99a",
  warning: "#ffc26b",
  focus: "#8fb0ff",
  radius: "8px",
  fontFamily: "system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif",
  fontSize: "16px",
};

const variables: Readonly<Record<keyof RelayTheme, string>> = {
  background: "--relay-color-background",
  surface: "--relay-color-surface",
  text: "--relay-color-text",
  mutedText: "--relay-color-muted",
  border: "--relay-color-border",
  accent: "--relay-color-accent",
  accentText: "--relay-color-accent-text",
  danger: "--relay-color-danger",
  success: "--relay-color-success",
  warning: "--relay-color-warning",
  focus: "--relay-color-focus",
  radius: "--relay-radius",
  fontFamily: "--relay-font-family",
  fontSize: "--relay-font-size",
};

/**
 * Merges the tenant's brand with a sub-tenant's brand: the sub-tenant's name, logo and theme tokens win where it sets them.
 */
export function resolveBrand(tenant?: RelayBrand, subtenant?: RelayBrand): RelayBrand {
  const theme: RelayTheme = { ...(tenant?.theme ?? {}), ...(subtenant?.theme ?? {}) };
  const darkTheme: RelayTheme = { ...(tenant?.darkTheme ?? {}), ...(subtenant?.darkTheme ?? {}) };
  const name = subtenant?.name ?? tenant?.name;
  const logoUrl = subtenant?.logoUrl ?? tenant?.logoUrl;
  return {
    ...(name === undefined ? {} : { name }),
    ...(logoUrl === undefined ? {} : { logoUrl }),
    theme,
    darkTheme,
  };
}

function channel(value: number): number {
  const scaled = value / 255;
  return scaled <= 0.03928 ? scaled / 12.92 : ((scaled + 0.055) / 1.055) ** 2.4;
}

/** Parses `#rgb` or `#rrggbb`; anything else gives null. */
export function parseHex(color: string): [number, number, number] | null {
  const match = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(color.trim());
  if (match === null) return null;
  const hex = match[1] as string;
  const full =
    hex.length === 3
      ? hex
          .split("")
          .map((digit) => digit + digit)
          .join("")
      : hex;
  return [
    Number.parseInt(full.slice(0, 2), 16),
    Number.parseInt(full.slice(2, 4), 16),
    Number.parseInt(full.slice(4, 6), 16),
  ];
}

/** The WCAG relative luminance of a hex colour, or null when it cannot be parsed. */
export function luminance(color: string): number | null {
  const rgb = parseHex(color);
  if (rgb === null) return null;
  return 0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) + 0.0722 * channel(rgb[2]);
}

/** The WCAG contrast ratio of two hex colours, or null when one cannot be parsed. */
export function contrastRatio(a: string, b: string): number | null {
  const la = luminance(a);
  const lb = luminance(b);
  if (la === null || lb === null) return null;
  const [light, dark] = la > lb ? [la, lb] : [lb, la];
  return (light + 0.05) / (dark + 0.05);
}

/** Black or white, whichever reads better on the colour (WCAG 2.2 AA for text on brand colours). */
export function readableTextOn(color: string): string {
  const white = contrastRatio(color, "#ffffff") ?? 21;
  const black = contrastRatio(color, "#000000") ?? 0;
  return white >= black ? "#ffffff" : "#000000";
}

/**
 * The CSS custom properties of a theme over the base theme of the colour scheme. A brand accent without its own text colour gets black or white text, whichever has the higher contrast.
 */
export function themeVariables(
  scheme: "light" | "dark",
  theme: RelayTheme = {},
): Record<string, string> {
  const base = scheme === "dark" ? darkTheme : lightTheme;
  const merged: Record<keyof RelayTheme, string> = { ...base, ...stripUndefined(theme) };
  if (theme.accent !== undefined && theme.accentText === undefined) {
    merged.accentText = readableTextOn(theme.accent);
  }
  const result: Record<string, string> = {};
  for (const key of Object.keys(variables) as (keyof RelayTheme)[]) {
    result[variables[key]] = merged[key];
  }
  return result;
}

function stripUndefined(theme: RelayTheme): Partial<Required<RelayTheme>> {
  const result: Partial<Record<keyof RelayTheme, string>> = {};
  for (const key of Object.keys(theme) as (keyof RelayTheme)[]) {
    const value = theme[key];
    if (value !== undefined) result[key] = value;
  }
  return result;
}
