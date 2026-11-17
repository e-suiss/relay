import { describe, expect, it } from 'vitest';
import { IntentQueue } from '../src/inbox/queue';
import { InboxStore, inTab } from '../src/inbox/store';
import type { InboxItem, RealtimeEnvelope } from '../src/types';
import {
  counters,
  fakeRandom,
  inboxItem,
  ITEM_ID,
  ITEM_ID_2,
  itemState,
  json,
  problem,
  recordingLogger,
  testHttp,
  type Responder,
} from './helpers';

const item = (overrides: Record<string, unknown> = {}) => inboxItem(overrides) as InboxItem;

const envelope = (
  t: string,
  d: Record<string, unknown>,
  version: number,
  id = `c${String(version)}`,
) =>
  ({
    t,
    v: 1,
    ts: '2026-11-18T09:00:00Z',
    id,
    d,
    counters: { unseen: version, unread: version, total: version, version },
  }) as RealtimeEnvelope;

describe('IN-27 inbox store versions', () => {
  it('IN-27 drops an item event whose state_version is not newer', () => {
    const store = new InboxStore();
    store.reset([item({ state_version: 3, title: 'v3' })], counters(1), 'c1');
    expect(store.applyItem(item({ state_version: 3, title: 'again' }))).toBe(false);
    expect(store.applyItem(item({ state_version: 2, title: 'old' }))).toBe(false);
    expect(store.item(ITEM_ID)?.title).toBe('v3');
    expect(store.applyItem(item({ state_version: 4, title: 'v4' }))).toBe(true);
    expect(store.item(ITEM_ID)?.title).toBe('v4');
  });

  it('IN-27 ignores counters whose version is not newer', () => {
    const store = new InboxStore();
    store.applyCounters(counters(5, 3));
    store.applyCounters(counters(4, 9));
    expect(store.currentCounters?.unread).toBe(3);
  });

  it('IN-26 applies item_updated changes and removes hidden items', () => {
    const store = new InboxStore();
    store.reset([item()], counters(1), 'c1');
    store.applyEnvelope(
      envelope(
        'inbox.item_updated',
        { item_id: ITEM_ID, state_version: 2, changes: { read: true } },
        2,
      ),
    );
    expect(store.item(ITEM_ID)?.read).toBe(true);
    expect(store.streamCursor).toBe('c2');
    expect(store.currentCounters?.version).toBe(2);
    store.applyEnvelope(
      envelope(
        'inbox.item_updated',
        { item_id: ITEM_ID, state_version: 3, changes: { hidden: true } },
        3,
      ),
    );
    expect(store.item(ITEM_ID)).toBeUndefined();
    store.applyEnvelope(
      envelope(
        'inbox.item_updated',
        { item_id: ITEM_ID, state_version: 3, changes: { hidden: false } },
        4,
      ),
    );
    expect(store.item(ITEM_ID)).toBeUndefined();
  });

  it('IN-27 a thin item_created asks for the item; bulk and resync ask for a sync', () => {
    const store = new InboxStore();
    expect(
      store.applyEnvelope(
        envelope(
          'inbox.item_created',
          { item: { id: ITEM_ID_2, state_version: 1 }, state_version: 1, thin: true },
          1,
        ),
      ),
    ).toEqual({ kind: 'fetch', itemId: ITEM_ID_2 });
    expect(
      store.applyEnvelope(
        envelope('inbox.items_bulk_updated', { scope: 'all', action: 'read' }, 2),
      ),
    ).toEqual({ kind: 'refresh' });
    expect(
      store.applyEnvelope(envelope('stream.resync_required', { reason: 'epoch_changed' }, 3)),
    ).toEqual({ kind: 'resync' });
  });

  it('IN-28 a cold page keeps a newer version already seen on the stream', () => {
    const store = new InboxStore();
    store.applyEnvelope(
      envelope(
        'inbox.item_created',
        { item: item({ state_version: 5, title: 'stream' }), state_version: 5 },
        1,
      ),
    );
    store.reset([item({ state_version: 4, title: 'page' })], counters(0), 'c9');
    expect(store.version(ITEM_ID)).toBe(5);
  });

  it('IN-9 tabs follow the item state', () => {
    const now = Date.parse('2026-11-18T09:00:00Z');
    expect(inTab(item(), 'unread', now)).toBe(true);
    expect(inTab(item({ archived: true }), 'inbox', now)).toBe(false);
    expect(inTab(item({ archived: true }), 'archived', now)).toBe(true);
    expect(inTab(item({ snoozed_until: '2026-11-19T00:00:00Z' }), 'snoozed', now)).toBe(true);
    expect(inTab(item({ snoozed_until: '2026-11-19T00:00:00Z' }), 'inbox', now)).toBe(false);
  });
});

function queueHarness(responder: Responder, session = 'session-a') {
  const harness = testHttp(responder);
  const store = new InboxStore();
  store.reset(
    [item({ state_version: 3 }), item({ id: ITEM_ID_2, state_version: 1 })],
    counters(1, 2),
    'c1',
  );
  const queue = new IntentQueue(
    harness.http,
    harness.store,
    store,
    fakeRandom(),
    recordingLogger(),
    session,
  );
  return { ...harness, inbox: store, queue };
}

const applied = (state: Record<string, unknown>, version: number) =>
  json(200, {
    object: 'inbox_intent_result',
    item_id: state.id,
    op: 'read',
    client_seq: 1,
    result: 'applied',
    state,
    counters: counters(version, 1),
  });

describe('IN-12 IN-13 offline intent queue', () => {
  it('IN-13 orders by client_seq, keeps the newest intent per item and persists the sequence', async () => {
    const { queue, store } = queueHarness(() => 'network');
    await queue.enqueue(ITEM_ID, 'read');
    await queue.enqueue(ITEM_ID_2, 'archive');
    await queue.enqueue(ITEM_ID, 'unread');
    const pending = await queue.pending();
    expect(pending.map((entry) => [entry.item_id, entry.op, entry.client_seq])).toEqual([
      [ITEM_ID_2, 'archive', 2],
      [ITEM_ID, 'unread', 3],
    ]);
    expect(pending[1]?.base_state_version).toBe(3);
    expect(store.entries.get('relay.inbox.client_seq')).toBe('3');
  });

  it('IN-12 applies the intent on screen at once', async () => {
    const { queue, inbox } = queueHarness(() => 'network');
    await queue.enqueue(ITEM_ID, 'read');
    expect(inbox.item(ITEM_ID)?.read).toBe(true);
  });

  it('IN-12 sends the intent with client_seq and base_state_version and applies the answer', async () => {
    const { queue, inbox, requests } = queueHarness(() =>
      applied(itemState({ state_version: 4, read: false }), 2),
    );
    await queue.enqueue(ITEM_ID, 'unread', { interactive: true });
    const result = await queue.flush();
    expect(result).toMatchObject({ sent: 1, dropped: 0, remaining: 0 });
    expect(requests[0]?.path).toBe(`/v1/subscriber/inbox/items/${ITEM_ID}/intents`);
    expect(requests[0]?.body).toEqual({ op: 'unread', client_seq: 1, base_state_version: 3 });
    expect(inbox.version(ITEM_ID)).toBe(4);
    expect(inbox.currentCounters?.version).toBe(2);
  });

  it('IN-12 (4) accepts the server state of a 409 silently for a background intent', async () => {
    const current = itemState({ state_version: 7, read: true });
    const { queue, inbox } = queueHarness(() => problem(409, 'inbox_item_conflict', { current }));
    await queue.enqueue(ITEM_ID, 'unread');
    const result = await queue.flush();
    expect(result.conflicts).toEqual([{ itemId: ITEM_ID, op: 'unread', notify: false }]);
    expect(inbox.version(ITEM_ID)).toBe(7);
    expect(inbox.item(ITEM_ID)?.read).toBe(true);
    expect(result.remaining).toBe(0);
  });

  it('IN-12 (4) tells the user only about a reverse change made on screen in this session', async () => {
    const current = itemState({ state_version: 7 });
    const { queue } = queueHarness(() => problem(409, 'inbox_item_conflict', { current }));
    await queue.enqueue(ITEM_ID, 'unarchive', { interactive: true });
    expect((await queue.flush()).conflicts[0]?.notify).toBe(true);
  });

  it('IN-13 (2) drops a queued reverse intent once a newer server state is known, and still sends monotone ones', async () => {
    const { queue, inbox, requests } = queueHarness(() =>
      applied(itemState({ id: ITEM_ID_2, state_version: 9 }), 3),
    );
    await queue.enqueue(ITEM_ID, 'unread');
    await queue.enqueue(ITEM_ID_2, 'read');
    inbox.applyState(itemState({ state_version: 5 }));
    inbox.applyState(itemState({ id: ITEM_ID_2, state_version: 8 }));
    const result = await queue.flush();
    expect(result).toMatchObject({ sent: 1, dropped: 1 });
    expect(requests.map((request) => (request.body as { op: string }).op)).toEqual(['read']);
  });

  it('IN-13 a network failure stops the flush and keeps the queue in order', async () => {
    const { queue } = queueHarness(() => 'network');
    await queue.enqueue(ITEM_ID, 'read');
    await queue.enqueue(ITEM_ID_2, 'read');
    const result = await queue.flush();
    expect(result).toMatchObject({ sent: 0, remaining: 2 });
  });

  it('IN-12 reuses the Idempotency-Key of a queued intent when it is sent again', async () => {
    let calls = 0;
    const { queue, requests } = queueHarness(() => {
      calls += 1;
      return calls <= 4 ? 'network' : applied(itemState({ state_version: 4 }), 2);
    });
    await queue.enqueue(ITEM_ID, 'read');
    await queue.flush();
    await queue.flush();
    expect(new Set(requests.map((request) => request.headers['Idempotency-Key'])).size).toBe(1);
  });
});
