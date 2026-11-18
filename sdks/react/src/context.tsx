import type { InboxItem } from "@esuiss/relay/browser";
import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type CSSProperties,
  type ReactNode,
} from "react";
import { createTranslator, resolveLocale, type Messages, type RelayLocale, type Translate } from "./i18n/index.js";
import { RelayRuntime, type InboxState, type RelayRuntimeOptions } from "./runtime.js";
import { relayStyles } from "./styles.js";
import type { TokenProvider } from "./tokens.js";
import { resolveBrand, themeVariables, type ColorScheme, type RelayBrand, type RelayTheme } from "./theme.js";

/** Where the components link to outside Relay. */
export interface RelayLinks {
  /** The Access page where the subscriber manages marketing consents (X-44). */
  readonly accessConsentUrl?: string;
  /** The origin of the Access approval surface; on an approval item only links to it are shown (IN-6). */
  readonly accessApprovalOrigin?: string;
  /** The Access approval link of an approval item when the item carries none. */
  readonly accessApprovalUrl?: (item: InboxItem) => string | null;
  /** The address of the preference center, focused on a category (X-16). */
  readonly preferencesHref?: (category: string | null) => string;
  /** Opens the preference center in the app instead of following a link (X-16). */
  readonly onOpenPreferences?: (category: string | null) => void;
}

/** Props of {@link RelayProvider}. */
export interface RelayProviderProps extends Partial<RelayRuntimeOptions> {
  /** A runtime shared with other roots; when given, the runtime options are ignored. */
  readonly runtime?: RelayRuntime;
  /** BCP 47 language tag; Turkish for `tr`, English otherwise. */
  readonly locale?: string;
  /** Overrides of single texts. */
  readonly messages?: Partial<Messages>;
  readonly theme?: RelayTheme;
  readonly brand?: RelayBrand;
  /** The sub-tenant's brand; it wins over the tenant's brand where it sets a value. */
  readonly subtenantBrand?: RelayBrand;
  readonly colorScheme?: ColorScheme;
  readonly links?: RelayLinks;
  readonly children?: ReactNode;
}

/** What every component reads from the provider. */
export interface RelayContextValue {
  readonly runtime: RelayRuntime;
  readonly locale: RelayLocale;
  readonly t: Translate;
  readonly brand: RelayBrand;
  /** Tokens over the brand's theme, for both colour schemes. */
  readonly theme: RelayTheme;
  readonly colorScheme: ColorScheme;
  readonly links: RelayLinks;
  readonly formatTime: (iso: string) => string;
}

const RelayContext = createContext<RelayContextValue | null>(null);

function provide(provider: TokenProvider | undefined): Promise<string> | string {
  if (provider === undefined) throw new Error("The token provider was removed.");
  return provider();
}

/**
 * Provides the runtime, language, texts, brand and theme to the components below it. The runtime holds only narrow tokens (X-32): a subscriber token for the inbox, toast and preference center and a portal token for the webhook portal.
 */
export function RelayProvider(props: RelayProviderProps): ReactNode {
  const { runtime: given, locale, messages, theme, brand, subtenantBrand, colorScheme, links, children } = props;
  const latest = useRef<Partial<RelayRuntimeOptions>>(props);
  latest.current = props;
  const hasToken = props.token !== undefined;
  const hasPortalToken = props.portalToken !== undefined;
  const baseUrl = props.baseUrl ?? "";
  const owned = useMemo(() => {
    if (given !== undefined) return null;
    const initial = latest.current;
    return new RelayRuntime({
      baseUrl,
      ...(hasToken ? { token: () => provide(latest.current.token) } : {}),
      ...(hasPortalToken ? { portalToken: () => provide(latest.current.portalToken) } : {}),
      ...(initial.fetch === undefined ? {} : { fetch: initial.fetch }),
      ...(initial.realtime === undefined ? {} : { realtime: initial.realtime }),
      ...(initial.tabs === undefined ? {} : { tabs: initial.tabs }),
      ...(initial.undoWindowMs === undefined ? {} : { undoWindowMs: initial.undoWindowMs }),
      ...(initial.storage === undefined ? {} : { storage: initial.storage }),
    });
  }, [given, baseUrl, hasToken, hasPortalToken]);
  const runtime = given ?? (owned as RelayRuntime);
  const resolvedLocale = resolveLocale(locale);
  const value = useMemo<RelayContextValue>(() => {
    const formatter = new Intl.DateTimeFormat(resolvedLocale === "tr" ? "tr-TR" : "en-GB", {
      dateStyle: "medium",
      timeStyle: "short",
    });
    const resolved = resolveBrand(brand, subtenantBrand);
    return {
      runtime: runtime,
      locale: resolvedLocale,
      t: createTranslator(resolvedLocale, messages),
      brand: resolved,
      theme: theme ?? {},
      colorScheme: colorScheme ?? "auto",
      links: links ?? {},
      formatTime: (iso: string) => {
        const time = Date.parse(iso);
        return Number.isNaN(time) ? iso : formatter.format(time);
      },
    };
  }, [runtime, resolvedLocale, messages, brand, subtenantBrand, theme, colorScheme, links]);
  return <RelayContext.Provider value={value}>{children}</RelayContext.Provider>;
}

/** The provider's value; throws outside a {@link RelayProvider}. */
export function useRelay(): RelayContextValue {
  const value = useContext(RelayContext);
  if (value === null) throw new Error("Relay components must be rendered inside <RelayProvider>.");
  return value;
}

function prefersDark(): boolean {
  return typeof window !== "undefined" && typeof window.matchMedia === "function"
    ? window.matchMedia("(prefers-color-scheme: dark)").matches
    : false;
}

/** The colour scheme in effect: the given one, or the system setting for `auto`. */
export function useResolvedScheme(scheme: ColorScheme): "light" | "dark" {
  const [dark, setDark] = useState(prefersDark);
  useEffect(() => {
    if (scheme !== "auto" || typeof window === "undefined" || typeof window.matchMedia !== "function") return;
    const query = window.matchMedia("(prefers-color-scheme: dark)");
    const listener = (event: MediaQueryListEvent) => setDark(event.matches);
    query.addEventListener("change", listener);
    return () => query.removeEventListener("change", listener);
  }, [scheme]);
  if (scheme === "auto") return dark ? "dark" : "light";
  return scheme;
}

/** Props of {@link RelayRoot}. */
export interface RelayRootProps {
  readonly className?: string;
  readonly label?: string;
  readonly as?: "div" | "section" | "aside" | "nav";
  readonly children?: ReactNode;
}

/** The themed root of a component: the theme's custom properties, the stylesheet and the language. */
export function RelayRoot({ className, label, as = "div", children }: RelayRootProps): ReactNode {
  const { theme, brand, colorScheme, locale } = useRelay();
  const scheme = useResolvedScheme(colorScheme);
  const style = useMemo(() => {
    const branded = scheme === "dark" ? brand.darkTheme : brand.theme;
    const variables = themeVariables(scheme, { ...(branded ?? {}), ...theme });
    const defaults: Record<string, string> = {};
    for (const [name, value] of Object.entries(variables)) {
      defaults[name.replace("--relay-", "--relay-default-")] = value;
    }
    return defaults as unknown as CSSProperties;
  }, [scheme, theme, brand]);
  const Element = as;
  return (
    <Element
      className={className === undefined ? "relay-root" : `relay-root ${className}`}
      style={style}
      lang={locale}
      data-color-scheme={scheme}
      {...(label === undefined ? {} : { "aria-label": label })}
    >
      <style>{relayStyles}</style>
      {children}
    </Element>
  );
}

/** The inbox state of the provider's runtime; the inbox runs while a component uses it. */
export function useInboxState(): InboxState {
  const { runtime } = useRelay();
  useEffect(() => runtime.acquireInbox(), [runtime]);
  return useSyncExternalStore(
    (listener) => runtime.subscribeInbox(listener),
    () => runtime.inboxState(),
    () => runtime.inboxState(),
  );
}

/** Opens the preference center for a category: the app's handler, else the configured link. */
export function usePreferenceShortcut(): {
  readonly href: (category: string | null) => string | null;
  readonly open: ((category: string | null) => void) | null;
} {
  const { links } = useRelay();
  return {
    href: (category) => links.preferencesHref?.(category) ?? null,
    open: links.onOpenPreferences ?? null,
  };
}
