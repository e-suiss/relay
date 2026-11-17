import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';
import { RelayHttp, TokenManager } from '../src/http';
import { memoryStore, type Clock, type Logger, type LogFields, type Random } from '../src/ports';

export const repoFile = (path: string): string =>
  join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', path);

export const readJson = <T>(path: string): T =>
  JSON.parse(readFileSync(repoFile(path), 'utf8')) as T;

export const readYaml = <T>(path: string): T => parse(readFileSync(repoFile(path), 'utf8')) as T;

export interface FakeClock extends Clock {
  time: number;
  readonly delays: number[];
  advance(ms: number): Promise<void>;
  pending(): number;
}

/** A manual clock: timers fire only when `advance` passes them. */
export function fakeClock(start = Date.parse('2026-11-18T09:00:00Z')): FakeClock {
  let id = 0;
  const timers = new Map<number, { at: number; callback: () => void }>();
  const clock: FakeClock = {
    time: start,
    delays: [],
    now: () => clock.time,
    setTimeout: (callback, ms) => {
      id += 1;
      clock.delays.push(ms);
      timers.set(id, { at: clock.time + ms, callback });
      return id;
    },
    clearTimeout: (handle) => {
      timers.delete(handle as number);
    },
    advance: async (ms) => {
      const target = clock.time + ms;
      await flushPromises();
      for (;;) {
        const due = [...timers.entries()]
          .filter(([, timer]) => timer.at <= target)
          .sort((a, b) => a[1].at - b[1].at)[0];
        if (!due) break;
        timers.delete(due[0]);
        clock.time = Math.max(clock.time, due[1].at);
        due[1].callback();
        await flushPromises();
      }
      clock.time = target;
      await flushPromises();
    },
    pending: () => timers.size,
  };
  return clock;
}

/** A clock whose timers fire on the next microtask, recording the requested delays. */
export function instantClock(start = Date.parse('2026-11-18T09:00:00Z')): Clock & {
  readonly delays: number[];
} {
  const delays: number[] = [];
  return {
    delays,
    now: () => start,
    setTimeout: (callback, ms) => {
      delays.push(ms);
      void Promise.resolve().then(callback);
      return delays.length;
    },
    clearTimeout: () => undefined,
  };
}

export async function flushPromises(rounds = 8): Promise<void> {
  for (let i = 0; i < rounds; i += 1) {
    await new Promise<void>((resolve) => {
      setImmediate(resolve);
    });
  }
}

export function fakeRandom(float = 0.5): Random & { count: number } {
  const random = {
    count: 0,
    float: () => float,
    uuid: () => {
      random.count += 1;
      return `00000000-0000-4000-8000-${String(random.count).padStart(12, '0')}`;
    },
  };
  return random;
}

export interface LoggedEvent {
  readonly level: 'debug' | 'warn';
  readonly event: string;
  readonly fields: LogFields | undefined;
}

export function recordingLogger(): Logger & { readonly events: LoggedEvent[] } {
  const events: LoggedEvent[] = [];
  return {
    events,
    debug: (event, fields) => events.push({ level: 'debug', event, fields }),
    warn: (event, fields) => events.push({ level: 'warn', event, fields }),
  };
}

export interface RecordedRequest {
  readonly method: string;
  readonly url: string;
  readonly path: string;
  readonly headers: Record<string, string>;
  readonly body: unknown;
}

export type Responder = (request: RecordedRequest) => Response | Promise<Response> | 'network';

export const json = (
  status: number,
  body: unknown,
  headers: Record<string, string> = {},
): Response =>
  new Response(body === null ? null : JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...headers },
  });

export const problem = (
  status: number,
  code: string,
  extra: Record<string, unknown> = {},
  headers: Record<string, string> = {},
) =>
  json(
    status,
    {
      type: `https://relay.example.com/v1/errors/${code}`,
      title: code,
      status,
      code,
      retryable: false,
      ...extra,
    },
    headers,
  );

export function mockFetch(responder: Responder) {
  const requests: RecordedRequest[] = [];
  const fetch = async (input: string, init: RequestInit): Promise<Response> => {
    const url = new URL(input);
    const headers = { ...(init.headers as Record<string, string>) };
    const request: RecordedRequest = {
      method: init.method ?? 'GET',
      url: input,
      path: url.pathname,
      headers,
      body: typeof init.body === 'string' ? (JSON.parse(init.body) as unknown) : undefined,
    };
    requests.push(request);
    const response = await responder(request);
    if (response === 'network') throw new TypeError('Network request failed');
    return response;
  };
  return { fetch, requests };
}

export const BASE_URL = 'https://relay.example.com';

export function testHttp(
  responder: Responder,
  options: { clock?: Clock; random?: Random; logger?: ReturnType<typeof recordingLogger> } = {},
) {
  const clock = options.clock ?? instantClock();
  const random = options.random ?? fakeRandom();
  const logger = options.logger ?? recordingLogger();
  const tokenCalls: boolean[] = [];
  let tokenCounter = 0;
  const tokens = new TokenManager(({ forceRefresh }) => {
    tokenCalls.push(forceRefresh);
    tokenCounter += 1;
    return Promise.resolve({ token: `subscriber-token-${String(tokenCounter)}` });
  }, clock);
  const { fetch, requests } = mockFetch(responder);
  const http = new RelayHttp({ baseUrl: BASE_URL, tokens, fetch, clock, random, logger });
  return { http, requests, tokens, tokenCalls, clock, random, logger, store: memoryStore() };
}

export const ITEM_ID = 'inb_01j9zq3k4m5n6p7q8r9s0t1v2w';
export const ITEM_ID_2 = 'inb_01j9zq3k4m5n6p7q8r9s0t1v2x';

export function inboxItem(overrides: Record<string, unknown> = {}) {
  return {
    object: 'inbox_item' as const,
    id: ITEM_ID,
    state_version: 1,
    seen: false,
    read: false,
    archived: false,
    hidden: false,
    expired: false,
    snoozed_until: null,
    seen_at: null,
    read_at: null,
    archived_at: null,
    created_at: '2026-11-18T08:00:00Z',
    last_activity_at: '2026-11-18T08:00:00Z',
    category: 'order_updates',
    tags: [],
    severity: null,
    group_key: null,
    title: 'Siparişiniz yolda',
    body: 'Kargo yarın teslim edilecek.',
    avatar_url: null,
    url: 'https://shop.example.com/orders/1',
    actions: [],
    data: [],
    locale: 'tr-TR',
    dir: 'ltr' as const,
    activity_count: 1,
    actor_count: 0,
    expires_at: null,
    ...overrides,
  };
}

export function itemState(overrides: Record<string, unknown> = {}) {
  return {
    id: ITEM_ID,
    state_version: 2,
    seen: true,
    read: true,
    archived: false,
    hidden: false,
    expired: false,
    snoozed_until: null,
    seen_at: '2026-11-18T09:00:00Z',
    read_at: '2026-11-18T09:00:00Z',
    archived_at: null,
    ...overrides,
  };
}

export const counters = (version: number, unread = 0, unseen = unread, total = unread) => ({
  object: 'inbox_counters' as const,
  unseen,
  unread,
  total,
  version,
});
