import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { RelayClient } from '../src/client';
import { sha256Hex } from '../src/digest';
import { DisplayedNotificationReporter, displayedDigest } from '../src/displayed';
import { memoryStore } from '../src/ports';
import { FakePushAdapter } from './fakes';
import {
  fakeClock,
  fakeRandom,
  flushPromises,
  json,
  mockFetch,
  problem,
  testHttp,
  type Responder,
} from './helpers';

const DLV = 'dlv_01j9zq3k4m5n6p7q8r9s0t1v2x';
const NTF = 'ntf_01j9zq3k4m5n6p7q8r9s0t1v2w';
const NTF_2 = 'ntf_01j9zq3k4m5n6p7q8r9s0t1v2x';
const PATH = '/v1/subscriber/displayed_notifications';

const nodeSha256 = (text: string) => createHash('sha256').update(text, 'utf8').digest('hex');

const accepted = (count = 1) =>
  json(202, { object: 'displayed_notifications', accepted: count, duplicates: 0 });

interface ReportedBody {
  notifications: { digest: string; displayed_at: string }[];
}

const notificationsOf = (body: unknown) => (body as ReportedBody).notifications;

function setup(responder: Responder = () => accepted()) {
  const clock = fakeClock();
  const harness = testHttp(responder, { clock });
  const reporter = new DisplayedNotificationReporter(
    harness.http,
    harness.store,
    clock,
    harness.random,
    harness.logger,
  );
  return { ...harness, clock, reporter };
}

describe('OP-54 displayed notification digests', () => {
  it('OP-54 is the lowercase hex SHA-256 of the UTF-8 id', () => {
    expect(sha256Hex('')).toBe('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(sha256Hex('abc')).toBe(
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    const long = `${'ğüşiöç'.repeat(40)}${NTF}`;
    for (const text of [NTF, long, 'x'.repeat(55), 'x'.repeat(56), 'x'.repeat(64)]) {
      expect(sha256Hex(text)).toBe(nodeSha256(text));
    }
    expect(displayedDigest(NTF)).toMatch(/^[0-9a-f]{64}$/);
  });
});

describe('OP-95 displayed notification reporting', () => {
  it('OP-95 reports a full queue of 20 at once with digests only and an Idempotency-Key', async () => {
    const { reporter, requests } = setup();
    for (let i = 0; i < 19; i += 1) await reporter.record(NTF);
    expect(requests).toHaveLength(0);
    await reporter.record(NTF_2);
    expect(requests).toHaveLength(1);
    expect(requests[0]?.method).toBe('POST');
    expect(requests[0]?.path).toBe(PATH);
    expect(requests[0]?.headers['Idempotency-Key']).toBe('00000000-0000-4000-8000-000000000001');
    const sent = notificationsOf(requests[0]?.body);
    expect(sent).toHaveLength(20);
    expect(sent[0]).toEqual({ digest: nodeSha256(NTF), displayed_at: '2026-11-18T09:00:00.000Z' });
    expect(sent[19]?.digest).toBe(nodeSha256(NTF_2));
    expect(JSON.stringify(requests[0]?.body)).not.toContain('ntf_');
    expect(await reporter.queued()).toBe(0);
  });

  it('OP-95 reports what is queued every 30 seconds and keeps a repeated id twice', async () => {
    const { reporter, requests, clock } = setup();
    await reporter.record(NTF);
    await reporter.record(NTF);
    await clock.advance(29_999);
    expect(requests).toHaveLength(0);
    await clock.advance(1);
    await flushPromises();
    expect(requests).toHaveLength(1);
    expect(notificationsOf(requests[0]?.body).map((item) => item.digest)).toEqual([
      nodeSha256(NTF),
      nodeSha256(NTF),
    ]);
    expect(clock.pending()).toBe(0);
  });

  it('OP-95 keeps a failed batch and sends it again with the same Idempotency-Key', async () => {
    let online = false;
    const { reporter, requests } = setup(() => (online ? accepted() : 'network'));
    await reporter.record(NTF);
    await reporter.flush();
    expect(await reporter.queued()).toBe(1);
    await reporter.record(NTF_2);
    online = true;
    await reporter.flush();
    const keys = requests.map((request) => request.headers['Idempotency-Key']);
    expect(keys).toEqual([
      '00000000-0000-4000-8000-000000000001',
      '00000000-0000-4000-8000-000000000001',
      '00000000-0000-4000-8000-000000000002',
    ]);
    expect(notificationsOf(requests[1]?.body)).toEqual(notificationsOf(requests[0]?.body));
    expect(await reporter.queued()).toBe(0);
  });

  it('OP-95 retries a failed batch on the next 30 second flush', async () => {
    let online = false;
    const { reporter, requests, clock } = setup(() =>
      online ? accepted() : problem(503, 'service_unavailable'),
    );
    await reporter.record(NTF);
    await reporter.flush();
    await flushPromises();
    online = true;
    await clock.advance(30_000);
    await flushPromises();
    expect(requests).toHaveLength(2);
    expect(requests[1]?.headers['Idempotency-Key']).toBe(
      requests[0]?.headers['Idempotency-Key'],
    );
    expect(await reporter.queued()).toBe(0);
  });

  it('OP-95 drops a batch older than 24 hours', async () => {
    const { reporter, requests, clock, logger } = setup(() => 'network');
    await reporter.record(NTF);
    await reporter.flush();
    reporter.stop();
    clock.time += 24 * 60 * 60 * 1000;
    await reporter.flush();
    expect(requests).toHaveLength(1);
    expect(await reporter.queued()).toBe(0);
    expect(logger.events.map((event) => event.event)).toContain('relay.displayed.expired');
  });

  it('OP-95 drops a batch Relay rejects as invalid', async () => {
    const { reporter, requests } = setup(() => problem(422, 'validation_failed'));
    await reporter.record(NTF);
    await reporter.flush();
    expect(requests).toHaveLength(1);
    expect(await reporter.queued()).toBe(0);
  });

  it('OP-95 sends at most 100 digests per request', async () => {
    const { http, requests, random, logger } = testHttp(() => accepted(100));
    const store = memoryStore();
    const entry = { digest: nodeSha256(NTF), displayed_at: '2026-11-18T09:00:00.000Z' };
    await store.setItem('relay.displayed.pending', JSON.stringify(Array(150).fill(entry)));
    const reporter = new DisplayedNotificationReporter(http, store, fakeClock(), random, logger);
    await reporter.flush();
    expect(requests.map((request) => notificationsOf(request.body).length)).toEqual([100, 50]);
    expect(new Set(requests.map((request) => request.headers['Idempotency-Key'])).size).toBe(2);
    expect(await reporter.queued()).toBe(0);
  });
});

function client(reportDisplayedNotifications?: boolean) {
  const { fetch, requests } = mockFetch((request) => {
    if (request.path.startsWith('/v1/subscriber/push_content/')) {
      return json(200, {
        object: 'push_content',
        delivery_id: DLV,
        notification_id: NTF,
        channel: 'push',
        locale: 'tr-TR',
        content: { title: 'Kargo', body: 'Yolda' },
      });
    }
    if (request.path === PATH) return accepted();
    return json(202, { object: 'push_receipt' });
  });
  const relay = new RelayClient({
    baseUrl: 'https://relay.example.com',
    tokenProvider: () => Promise.resolve({ token: 'subscriber-token' }),
    storage: memoryStore(),
    realtime: false,
    fetch,
    clock: fakeClock(),
    random: fakeRandom(),
    push: { adapter: new FakePushAdapter(), categories: [] },
    ...(reportDisplayedNotifications === undefined ? {} : { reportDisplayedNotifications }),
  });
  return { relay, requests };
}

const contentFree = {
  data: {
    relay_id: DLV,
    relay_neutral_title: 'New notification',
    relay_neutral_body: 'You have a new notification.',
  },
};

describe('OP-95 the client reports displayed notifications only when asked', () => {
  it('OP-95 reports nothing by default', async () => {
    const { relay, requests } = client();
    expect(relay.displayedNotifications).toBeNull();
    await relay.push?.received(contentFree, 'displayed');
    await relay.reportDisplayed(NTF);
    relay.background();
    await flushPromises();
    expect(requests.map((request) => request.path)).not.toContain(PATH);
  });

  it('OP-95 queues a shown push and an id the app displayed, and reports them in the background', async () => {
    const { relay, requests } = client(true);
    await relay.push?.received(contentFree, 'displayed');
    await relay.reportDisplayed(NTF_2);
    expect(await relay.displayedNotifications?.queued()).toBe(2);
    relay.background();
    await flushPromises();
    const reports = requests.filter((request) => request.path === PATH);
    expect(reports).toHaveLength(1);
    expect(notificationsOf(reports[0]?.body).map((item) => item.digest)).toEqual([
      nodeSha256(NTF),
      nodeSha256(NTF_2),
    ]);
  });

  it('OP-95 a push whose notification id is unknown is not queued', async () => {
    const { relay } = client(true);
    await relay.push?.received(
      { notification: { title: 'Visible', body: 'Text' }, data: { relay_id: DLV } },
      'displayed',
    );
    expect(await relay.displayedNotifications?.queued()).toBe(0);
  });
});
