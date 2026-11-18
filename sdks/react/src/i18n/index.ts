import { en, type MessageKey, type Messages } from "./en.js";
import { tr } from "./tr.js";

export { en, tr, type MessageKey, type Messages };

/** The languages the components ship texts for. */
export type RelayLocale = "en" | "tr";

/** The texts of every shipped language. */
export const catalogs: Readonly<Record<RelayLocale, Messages>> = { en, tr };

/** Values of the `{name}` placeholders of a text. */
export type MessageValues = Readonly<Record<string, string | number>>;

/** A text lookup bound to one language. */
export type Translate = (key: MessageKey, values?: MessageValues) => string;

/** The shipped language for a BCP 47 tag: Turkish for `tr` and its regions, English otherwise. */
export function resolveLocale(tag: string | undefined): RelayLocale {
  return tag?.toLowerCase().split(/[-_]/)[0] === "tr" ? "tr" : "en";
}

/** The `{name}` placeholders of a text, sorted. */
export function placeholders(text: string): string[] {
  return [...new Set([...text.matchAll(/\{([a-z][a-zA-Z0-9]*)\}/g)].map((match) => match[1] as string))].sort();
}

/** Fills the `{name}` placeholders of a text; an unknown placeholder stays as written. */
export function format(text: string, values: MessageValues = {}): string {
  return text.replace(/\{([a-z][a-zA-Z0-9]*)\}/g, (whole, name: string) => {
    const value = values[name];
    return value === undefined ? whole : String(value);
  });
}

/** A text lookup for a language with optional overrides of single texts. */
export function createTranslator(
  locale: RelayLocale,
  overrides: Partial<Messages> = {},
): Translate {
  const catalog = catalogs[locale];
  return (key, values) => format(overrides[key] ?? catalog[key], values);
}
