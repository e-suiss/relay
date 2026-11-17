import { describe, expect, it } from 'vitest';
import { IntentQueue } from '../src/inbox/queue';
import { InboxStore } from '../src/inbox/store';
import { InboxSync } from '../src/inbox/sync';
import type { RealtimeConnection } from '../src/realtime/connection';
import type { RealtimeEnvelope } from '../src/types';
import {
  counters,
  fakeRandom,
  inboxItem,
  ITEM_ID,
  ITEM_ID_2,
  itemState,
  json,
  recordingLogger,
  testHttp,
  type RecordedRequest,
} from './helpers';

type Handler = (request: RecordedRequest) => Response | 'network' | Promise<Response>;

function harness(routes: Record<string, Handler>) {
  const order: string[] = [];
  const h = testHttp((request) => {
    order.push(`${request.method} ${request.path}`);
    const handler = routes[`${request.method} ${request.path}`];
    return handler ? handler(request) : json(404, { code: 'not_found' });
  });
  const store = new InboxStore();
  const queue = new IntentQueue(h.http, h.store, store, fakeRandom(), recordingLogger(), 's');
  const sync = new InboxSync({ http: h.http, store, queue, clock: h.clock, logger: h.logger, openWaitMs: 0 });
  const connection = {
    current: 'idle',
    start: () => {
      order.push('connect');
    },
    stop: () => {
      order.push('disconnect');
    },
  };
  sync.attach(connection as unknown as RealtimeConnection);
  return { ...h, order, store, queue, sync, connection };
}

const list = (items: unknown[], extra: Record<string, unknown> = {}) =>
  json(200, {
    object: 'list',
    data: items,
    has_more: false,
    next_cursor: null,
    previous_cursor: null,
    counters: counters(3, items.length),
    cursor: 'c10',
    ...extra,
  });

const changes = (extra: Record<string, unknown> = {}) =>
  json(200, {
    object: 'inbox_changes',
    changes: [],
    cursor: 'c20',
    has_more: false,
    truncated: false,
    resync_required: false,
    counters: counters(5, 1),
    ...extra,
  });

describe('IN-35 IN-21 foreground order', () => {
  it('IN-35 counters, then the stream, then the sync, then the offline queue', async () => {
    const h = harness({
      'GET /v1/subscriber/inbox/counters': () => json(200, counters(2, 1)),
      'GET /v1/subscriber/inbox/items': () => list([inboxItem()]),
      'POST /v1/subscriber/inbox/items/inb_01j9zq3k4m5n6p7q8r9s0t1v2x/intents': () =>
        json(200, {
          object: 'inbox_intent_result',
          item_id: ITEM_ID_2,
          op: 'read',
          client_seq: 1,
          result: 'applied',
          state: itemState({ id: ITEM_ID_2, state_version: 2 }),
          counters: counters(9, 1),
        }),
    });
    await h.queue.enqueue(ITEM_ID_2, 'read');
    await h.sync.foreground();
    expect(h.order).toEqual([
      'GET /v1/subscriber/inbox/counters',
      'connect',
      'GET /v1/subscriber/inbox/items',
      `POST /v1/subscriber/inbox/items/${ITEM_ID_2}/intents`,
    ]);
  });

  it('IN-35 the background closes the stream', () => {
    const h = harness({});
    h.sync.background();
    expect(h.order).toEqual(['disconnect']);
  });

  it('IN-21 reports counters that disagree with a complete list', async () => {
    const h = harness({
      'GET /v1/subscriber/inbox/items': () => list([inboxItem()], { counters: counters(3, 4) }),
      'POST /v1/subscriber/inbox/counters/inconsistency': () =>
        json(200, { object: 'inbox_reconciliation', result: 'repaired', counters: counters(4, 1) }),
    });
    await h.sync.sync();
    expect(h.order).toContain('POST /v1/subscriber/inbox/counters/inconsistency');
    expect(h.store.currentCounters?.unread).toBe(1);
  });

  it('IN-21 does not report while more pages exist', async () => {
    const h = harness({
      'GET /v1/subscriber/inbox/items': () =>
        list([inboxItem()], { counters: counters(3, 40), has_more: true, next_cursor: 'p2' }),
    });
    await h.sync.sync();
    expect(h.order).toEqual(['GET /v1/subscriber/inbox/items']);
  });
});

describe('IN-28 IN-29 sync', () => {
  it('IN-29 uses the delta from the stream cursor once the list is loaded', async () => {
    const h = harness({
      'GET /v1/subscriber/inbox/items': () => list([inboxItem()]),
      'GET /v1/subscriber/inbox/changes': () =>
        changes({ changes: [{ type: 'updated', item_id: ITEM_ID, state_version: 2, cursor: 'c11', item: inboxItem({ state_version: 2, read: true }) }] }),
    });
    await h.sync.sync();
    await h.sync.sync();
    expect(h.requests[1]?.url).toContain('since=c10');
    expect(h.store.item(ITEM_ID)?.read).toBe(true);
    expect(h.store.streamCursor).toBe('c20');
  });

  it('IN-29 goes back to a cold sync when the delta is truncated', async () => {
    const h = harness({
      'GET /v1/subscriber/inbox/items': () => list([inboxItem()]),
      'GET /v1/subscriber/inbox/changes': () => changes({ truncated: true }),
    });
    await h.sync.sync();
    await h.sync.sync();
    expect(h.order).toEqual([
      'GET /v1/subscriber/inbox/items',
      'GET /v1/subscriber/inbox/changes',
      'GET /v1/subscriber/inbox/items',
    ]);
  });

  it('IN-28 buffers stream events during a sync and applies them by version afterwards', async () => {
    let release: (() => void) | undefined;
    const h = harness({
      'GET /v1/subscriber/inbox/items': () =>
        new Promise<Response>((resolve) => {
          release = () => {
            resolve(list([inboxItem({ state_version: 1 })]));
          };
        }),
    });
    const running = h.sync.sync();
    await new Promise((resolve) => setImmediate(resolve));
    h.sync.envelope({
      t: 'inbox.item_updated',
      v: 1,
      ts: '2026-11-18T09:00:00Z',
      id: 'c11',
      d: { item_id: ITEM_ID, state_version: 2, changes: { read: true } },
      counters: { unseen: 0, unread: 0, total: 1, version: 4 },
    } as RealtimeEnvelope);
    expect(h.store.snapshot().ready).toBe(false);
    release?.();
    await running;
    expect(h.store.item(ITEM_ID)?.read).toBe(true);
    expect(h.store.version(ITEM_ID)).toBe(2);
  });

  it('IN-50 mark all read writes and then syncs', async () => {
    const h = harness({
      'POST /v1/subscriber/inbox/read_all': () =>
        json(200, { object: 'inbox_read_all_result', scope: 'all', category: null, updated: 2, cut_off: '2026-11-18T09:00:00Z', counters: counters(8, 0) }),
      'GET /v1/subscriber/inbox/items': () => list([], { counters: counters(8, 0) }),
    });
    const result = await h.sync.readAll();
    expect(result.updated).toBe(2);
    expect(h.requests[0]?.headers['Idempotency-Key']).toBeDefined();
    expect(h.store.currentCounters?.unread).toBe(0);
  });
});
