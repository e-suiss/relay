import { createContext, useContext, useEffect, useMemo, useSyncExternalStore, type ReactNode } from 'react';
import { AppState, useColorScheme } from 'react-native';
import type { RelayClient } from '../client';
import { resolveLocale, translate, type MessageKey, type RelayLocale } from '../i18n';
import type { InboxSnapshot } from '../inbox/store';
import { buildTheme, type RelayBrand, type RelayColors, type RelayTheme } from './theme';

export interface RelayUi {
  readonly client: RelayClient;
  readonly theme: RelayTheme;
  readonly locale: RelayLocale;
  readonly t: (key: MessageKey, values?: Readonly<Record<string, string | number>>) => string;
}

const RelayContext = createContext<RelayUi | null>(null);

export interface RelayProviderProps {
  readonly client: RelayClient;
  readonly children?: ReactNode;
  readonly scheme?: 'light' | 'dark' | 'system';
  readonly brand?: RelayBrand;
  readonly theme?: Partial<Omit<RelayTheme, 'colors'>> & { colors?: Partial<RelayColors> };
  readonly locale?: string;
  readonly messages?: Partial<Record<MessageKey, string>>;
  readonly manageLifecycle?: boolean;
}

// X-32
/** Supplies the client, theme, brand and locale to Relay components, and by default follows the app's foreground and background. */
export function RelayProvider(props: RelayProviderProps) {
  const system = useColorScheme();
  const scheme = props.scheme === 'light' || props.scheme === 'dark'
    ? props.scheme
    : system === 'dark'
      ? 'dark'
      : 'light';
  const locale = props.locale ? resolveLocale(props.locale) : props.client.locale;
  const { client, brand, theme: overrides, messages } = props;
  const value = useMemo<RelayUi>(
    () => ({
      client,
      theme: buildTheme(scheme, brand, overrides),
      locale,
      t: (key, values) => translate(locale, key, values, messages),
    }),
    [client, scheme, brand, overrides, locale, messages],
  );
  useRelayLifecycle(props.manageLifecycle === false ? null : client);
  return <RelayContext.Provider value={value}>{props.children}</RelayContext.Provider>;
}

/** The Relay UI context; throws outside a `RelayProvider`. */
export function useRelay(): RelayUi {
  const value = useContext(RelayContext);
  if (!value) throw new Error('Relay components must be inside a RelayProvider');
  return value;
}

/** The current inbox snapshot, updated on every change. */
export function useInbox(): InboxSnapshot {
  const { client } = useRelay();
  return useSyncExternalStore(
    (listener) => client.inbox.subscribe(listener),
    () => client.inbox.snapshot(),
    () => client.inbox.snapshot(),
  );
}

// IN-35
/** Starts the client and moves it to the background and back with the app. */
export function useRelayLifecycle(client: RelayClient | null): void {
  useEffect(() => {
    if (!client) return undefined;
    void client.start().catch(() => undefined);
    let last: string = AppState.currentState;
    const subscription = AppState.addEventListener('change', (next) => {
      if (next === 'active' && last !== 'active') void client.foreground().catch(() => undefined);
      if (next === 'background') client.background();
      last = next;
    });
    return () => {
      subscription.remove();
      client.background();
    };
  }, [client]);
}
