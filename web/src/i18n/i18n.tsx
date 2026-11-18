import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { en, type MessageKey, type Messages } from "./en";
import { tr } from "./tr";
import { readStored, writeStored } from "../app/storage";

export type Locale = "tr" | "en";
export type Vars = Record<string, string | number>;

export const catalogs: Record<Locale, Messages> = { en, tr };
export const locales: readonly Locale[] = ["tr", "en"];

export function format(template: string, vars: Vars = {}): string {
  return template.replace(/\{(\w+)\}/g, (match, name: string) => {
    const value = vars[name];
    return value === undefined ? match : String(value);
  });
}

export function translate(
  locale: Locale,
  key: MessageKey,
  vars?: Vars,
): string {
  return format(catalogs[locale][key], vars);
}

export function placeholders(template: string): string[] {
  return [...template.matchAll(/\{(\w+)\}/g)]
    .map((match) => match[1] ?? "")
    .sort();
}

function initialLocale(): Locale {
  const stored = readStored("relay.console.locale");
  if (stored === "tr" || stored === "en") return stored;
  return navigator.language.toLowerCase().startsWith("tr") ? "tr" : "en";
}

interface I18n {
  locale: Locale;
  setLocale: (locale: Locale) => void;
  t: (key: MessageKey, vars?: Vars) => string;
}

const I18nContext = createContext<I18n | null>(null);

export function I18nProvider({
  children,
  locale: fixed,
}: {
  children: ReactNode;
  locale?: Locale;
}) {
  const [locale, setLocaleState] = useState<Locale>(
    () => fixed ?? initialLocale(),
  );

  useEffect(() => {
    document.documentElement.lang = locale;
    document.title = translate(locale, "app.title");
  }, [locale]);

  const setLocale = useCallback((next: Locale) => {
    writeStored("relay.console.locale", next);
    setLocaleState(next);
  }, []);

  const value = useMemo<I18n>(
    () => ({
      locale,
      setLocale,
      t: (key, vars) => translate(locale, key, vars),
    }),
    [locale, setLocale],
  );

  return <I18nContext value={value}>{children}</I18nContext>;
}

export function useI18n(): I18n {
  const value = useContext(I18nContext);
  if (value === null) throw new Error("useI18n outside I18nProvider");
  return value;
}
