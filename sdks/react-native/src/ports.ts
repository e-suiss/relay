export const API_VERSION = '2026-11-01';

export const SDK_NAME = '@esuiss/relay-react-native';

/** A Relay subscriber token handed over by the host app, with its expiry in epoch milliseconds when known. */
export interface SubscriberToken {
  readonly token: string;
  readonly expiresAt?: number;
}

/** Supplies the subscriber token. The host app owns the Access session and the token exchange; the SDK never sees a secret. */
export type TokenProvider = (options: {
  readonly forceRefresh: boolean;
}) => Promise<SubscriberToken>;

export type TimerHandle = number | object;

/** Time source and timers, replaceable in tests. */
export interface Clock {
  now(): number;
  setTimeout(callback: () => void, ms: number): TimerHandle;
  clearTimeout(handle: TimerHandle): void;
}

/** Randomness source, replaceable in tests. */
export interface Random {
  float(): number;
  uuid(): string;
}

/** Durable key-value storage with the AsyncStorage shape. */
export interface KeyValueStore {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
  removeItem(key: string): Promise<void>;
}

export type LogFields = Readonly<Record<string, string | number | boolean | null>>;

/** Diagnostic sink. It receives event names and non-personal fields only: never tokens, push tokens or device status values. */
export interface Logger {
  debug(event: string, fields?: LogFields): void;
  warn(event: string, fields?: LogFields): void;
}

export type FetchLike = (input: string, init: RequestInit) => Promise<Response>;

export const systemClock: Clock = {
  now: () => Date.now(),
  setTimeout: (callback, ms) => setTimeout(callback, ms),
  clearTimeout: (handle) => {
    clearTimeout(handle as ReturnType<typeof setTimeout>);
  },
};

const hex = (bytes: Uint8Array): string =>
  Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');

/** UUID version 4 text from 16 random bytes. */
export function uuidFromBytes(bytes: Uint8Array): string {
  const b = Uint8Array.from(bytes.subarray(0, 16));
  b[6] = ((b[6] ?? 0) & 0x0f) | 0x40;
  b[8] = ((b[8] ?? 0) & 0x3f) | 0x80;
  const h = hex(b);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
}

interface CryptoLike {
  getRandomValues<T extends ArrayBufferView>(array: T): T;
}

const mathSource: CryptoLike = {
  getRandomValues: <T extends ArrayBufferView>(array: T): T => {
    const bytes = new Uint8Array(array.buffer, array.byteOffset, array.byteLength);
    for (let i = 0; i < bytes.length; i += 1) bytes[i] = Math.floor(Math.random() * 256);
    return array;
  },
};

/** Randomness from `crypto.getRandomValues` when the runtime has it, else from `Math.random`; it only spreads retries and names idempotency keys, it protects nothing. */
export function cryptoRandom(): Random {
  const source = (globalThis as { crypto?: CryptoLike }).crypto ?? mathSource;
  return {
    float: () => {
      const word = source.getRandomValues(new Uint32Array(1))[0] ?? 0;
      return word / 0x1_0000_0000;
    },
    uuid: () => uuidFromBytes(source.getRandomValues(new Uint8Array(16))),
  };
}

export const silentLogger: Logger = {
  debug: () => undefined,
  warn: () => undefined,
};

/** In-memory store for tests and for apps that do not persist. */
export function memoryStore(): KeyValueStore & { readonly entries: Map<string, string> } {
  const entries = new Map<string, string>();
  return {
    entries,
    getItem: (key) => Promise.resolve(entries.get(key) ?? null),
    setItem: (key, value) => {
      entries.set(key, value);
      return Promise.resolve();
    },
    removeItem: (key) => {
      entries.delete(key);
      return Promise.resolve();
    },
  };
}
