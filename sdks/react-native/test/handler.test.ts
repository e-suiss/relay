import { describe, expect, it } from 'vitest';
import type { PushContentSource } from '../src/push/adapter';
import { PushHandler } from '../src/push/handler';
import { ReceiptQueue } from '../src/push/receipts';
import type { InboxCounters } from '../src/types';
import { FakePushAdapter } from './fakes';
import { counters, fakeClock, json, problem, testHttp } from './helpers';

const DLV = 'dlv_01j9zq3k4m5n6p7q8r9s0t1v2x';
const NTF = 'ntf_01j9zq3k4m5n6p7q8r9s0t1v2w';

const contentFree = {
  data: { relay_id: DLV, relay_neutral_title: 'New notification', relay_neutral_body: 'You have a new notification.' },
};

function setup(options: {
  content?: PushContentSource;
  unread?: number;
  receiptStatus?: number;
} = {}) {
  const harness = testHttp(() =>
    options.receiptStatus && options.receiptStatus >= 400
      ? problem(options.receiptStatus, options.receiptStatus === 404 ? 'delivery_not_found' : 'service_unavailable')
      : json(202, { object: 'push_receipt' }),
  );
  const adapter = new FakePushAdapter();
  const receipts = new ReceiptQueue(harness.http, harness.store, harness.clock, harness.random, harness.logger);
  const syncs: number[] = [];
  const handler = new PushHandler({
    adapter,
    contentSource: options.content ?? { fetch: () => Promise.resolve(null) },
    receipts,
    store: harness.store,
    clock: harness.clock,
    logger: harness.logger,
    locale: () => 'tr',
    syncCounters: (): Promise<InboxCounters> => {
      syncs.push(1);
      return Promise.resolve(counters(9, options.unread ?? 0));
    },
  });
  return { ...harness, adapter, receipts, handler, syncs };
}

describe('CH-33 content-free push', () => {
  it('CH-33 fetches the content over TLS and shows it, never the payload', async () => {
    const { handler, adapter } = setup({
      content: { fetch: () => Promise.resolve({ title: 'Kargo', body: 'Yarın geliyor', url: 'https://shop.example.com/o/1' }) },
    });
    const shown = await handler.received(contentFree, 'display');
    expect(shown).toMatchObject({ title: 'Kargo', body: 'Yarın geliyor', contentFree: true, fetched: true });
    expect(adapter.displayed[0]).toMatchObject({ deliveryId: DLV, title: 'Kargo', body: 'Yarın geliyor' });
  });

  it('CH-33 (4) falls back to the neutral text of the payload when the content cannot be fetched', async () => {
    const { handler } = setup({ content: { fetch: () => Promise.reject(new Error('offline')) } });
    expect(await handler.received(contentFree, 'none')).toMatchObject({
      title: 'New notification',
      body: 'You have a new notification.',
      fetched: false,
    });
  });

  it('CH-33 (4) falls back to the localized generic text when the payload has none and the fetch times out', async () => {
    const clock = fakeClock();
    const harness = testHttp(() => json(202, {}), { clock });
    const handler = new PushHandler({
      adapter: new FakePushAdapter('apns'),
      contentSource: { fetch: () => new Promise(() => undefined) },
      receipts: new ReceiptQueue(harness.http, harness.store, clock, harness.random, harness.logger),
      store: harness.store,
      clock,
      logger: harness.logger,
      locale: () => 'tr',
      syncCounters: () => Promise.resolve(null),
      fetchTimeoutMs: 1000,
    });
    const pending = handler.received(
      { aps: { 'mutable-content': 1 }, relay: { id: DLV } },
      'none',
    );
    await clock.advance(1000);
    expect(await pending).toMatchObject({ title: 'Yeni bildirim', body: 'Yeni bir bildiriminiz var.', fetched: false });
  });
});

describe('CH-32 push receipts', () => {
  it('CH-32 records displayed after the SDK showed a data message and clicked when opened', async () => {
    const { handler, requests } = setup();
    await handler.received(contentFree, 'display');
    const opened = await handler.opened(contentFree);
    expect(opened).toEqual({ deliveryId: DLV, url: null });
    expect(requests.map((request) => (request.body as { receipt: string }).receipt)).toEqual(['displayed', 'clicked']);
    expect(requests[0]?.path).toBe('/v1/subscriber/push_receipts');
    expect(requests[0]?.body).toMatchObject({ delivery_id: DLV, occurred_at: expect.any(String) as string });
  });

  it('CH-32 keeps receipts on the device while Relay cannot be reached and resends with the same key', async () => {
    const { handler, receipts, requests } = setup({ receiptStatus: 503 });
    await handler.received(contentFree, 'displayed');
    expect(await receipts.pending()).toBe(1);
    const keys = new Set(requests.map((request) => request.headers['Idempotency-Key']));
    expect(keys.size).toBe(1);
  });

  it('CH-32 drops a receipt for a delivery Relay does not know', async () => {
    const { handler, receipts } = setup({ receiptStatus: 404 });
    await handler.received(contentFree, 'displayed');
    expect(await receipts.pending()).toBe(0);
  });

  it('CH-32 records no receipt when the push was only read', async () => {
    const { handler, requests } = setup();
    await handler.received(contentFree, 'none');
    expect(requests).toHaveLength(0);
  });
});

describe('IN-38 removal from other devices', () => {
  it('IN-38 a read signal removes the notification it names once the content told its notification', async () => {
    const { handler, adapter } = setup({
      content: { fetch: () => Promise.resolve({ title: 'a', body: 'b', notificationId: NTF }) },
    });
    await handler.received(contentFree, 'display');
    await handler.received({ data: { relay_sync: '1', relay_counter_version: '10', relay_read: NTF } }, 'none');
    expect(adapter.removed).toEqual(['n1']);
  });

  it('IN-38 an unmatched read or an iOS sync clears shown notifications once nothing is unread', async () => {
    const { handler, adapter, syncs } = setup({ unread: 0 });
    await handler.received(contentFree, 'display');
    await handler.received({ data: { relay_sync: '1', relay_read: NTF } }, 'none');
    expect(syncs).toHaveLength(1);
    expect(adapter.removed).toEqual(['n1']);
  });

  it('IN-38 keeps shown notifications while unread items remain', async () => {
    const { handler, adapter } = setup({ unread: 2 });
    await handler.received(contentFree, 'display');
    await handler.received({ data: { relay_sync: '1', relay_counter_version: '4' } }, 'none');
    expect(adapter.removed).toEqual([]);
  });
});
