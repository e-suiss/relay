import { describe, expect, it } from 'vitest';
import { RelayClient } from '../src/client';
import { memoryStore } from '../src/ports';
import { pushContentOf, RelayPushContentSource } from '../src/push/content';
import { FakePushAdapter } from './fakes';
import { fakeClock, fakeRandom, json, mockFetch, problem, testHttp } from './helpers';

const DLV = 'dlv_01j9zq3k4m5n6p7q8r9s0t1v2x';
const NTF = 'ntf_01j9zq3k4m5n6p7q8r9s0t1v2w';

const pushContent = (content: Record<string, unknown>) => ({
  object: 'push_content',
  delivery_id: DLV,
  notification_id: NTF,
  channel: 'push',
  locale: 'tr-TR',
  content,
});

const contentFree = {
  data: {
    relay_id: DLV,
    relay_neutral_title: 'New notification',
    relay_neutral_body: 'You have a new notification.',
  },
};

describe('CH-33 push content from Relay', () => {
  it('CH-33 fetches the content by the delivery id with the subscriber token', async () => {
    const { http, requests } = testHttp(() =>
      json(200, pushContent({ title: 'Kargo', body: 'Yolda', url: 'https://a.example/o' })),
    );
    const content = await new RelayPushContentSource(http).fetch(DLV);
    expect(content).toEqual({
      title: 'Kargo',
      body: 'Yolda',
      url: 'https://a.example/o',
      notificationId: NTF,
    });
    expect(requests).toHaveLength(1);
    expect(requests[0]?.method).toBe('GET');
    expect(requests[0]?.path).toBe(`/v1/subscriber/push_content/${DLV}`);
    expect(requests[0]?.headers.Authorization).toMatch(/^Bearer /);
    expect(requests[0]?.headers['Idempotency-Key']).toBeUndefined();
  });

  it('CH-33 (4) a delivery Relay does not give answers null and is not retried', async () => {
    const { http, requests } = testHttp(() => problem(404, 'delivery_not_found'));
    expect(await new RelayPushContentSource(http).fetch(DLV)).toBeNull();
    expect(requests).toHaveLength(1);
  });

  it('CH-33 (4) a network failure or a server error answers null without retrying', async () => {
    const network = testHttp(() => 'network');
    expect(await new RelayPushContentSource(network.http).fetch(DLV)).toBeNull();
    expect(network.requests).toHaveLength(1);
    const unavailable = testHttp(() => problem(503, 'service_unavailable'));
    expect(await new RelayPushContentSource(unavailable.http).fetch(DLV)).toBeNull();
    expect(unavailable.requests).toHaveLength(1);
  });

  it('CH-33 content with neither a title nor a body counts as not fetched', () => {
    expect(pushContentOf(pushContent({ url: 'https://a.example' }) as never)).toBeNull();
    expect(pushContentOf(pushContent({ body: 'Only body' }) as never)).toEqual({
      title: null,
      body: 'Only body',
      url: null,
      notificationId: NTF,
    });
  });
});

function pushClient(status: number, body: unknown) {
  const { fetch, requests } = mockFetch((request) =>
    request.path.startsWith('/v1/subscriber/push_content/')
      ? status === 200
        ? json(200, body)
        : problem(status, 'delivery_not_found')
      : json(202, { object: 'push_receipt' }),
  );
  const relay = new RelayClient({
    baseUrl: 'https://relay.example.com',
    tokenProvider: () => Promise.resolve({ token: 'subscriber-token' }),
    storage: memoryStore(),
    realtime: false,
    fetch,
    clock: fakeClock(),
    random: fakeRandom(),
    locale: 'tr-TR',
    push: { adapter: new FakePushAdapter(), categories: [] },
  });
  return { relay, requests };
}

describe('CH-33 the client fetches push content from Relay by default', () => {
  it('CH-33 a content-free push shows the content Relay returns', async () => {
    const { relay, requests } = pushClient(200, pushContent({ title: 'Kargo', body: 'Yolda' }));
    expect(await relay.push?.received(contentFree, 'none')).toMatchObject({
      title: 'Kargo',
      body: 'Yolda',
      contentFree: true,
      fetched: true,
    });
    const paths = requests.map((request) => request.path);
    expect(paths).toEqual([`/v1/subscriber/push_content/${DLV}`]);
  });

  it('CH-33 (4) a content-free push keeps its neutral text when Relay answers not found', async () => {
    const { relay } = pushClient(404, null);
    expect(await relay.push?.received(contentFree, 'none')).toMatchObject({
      title: 'New notification',
      body: 'You have a new notification.',
      contentFree: true,
      fetched: false,
    });
  });

  it('CH-33 a push that carries its content is shown without a fetch', async () => {
    const { relay, requests } = pushClient(200, pushContent({ title: 'x', body: 'y' }));
    await relay.push?.received(
      { notification: { title: 'Visible', body: 'Text' }, data: { relay_id: DLV } },
      'none',
    );
    expect(requests).toHaveLength(0);
  });
});
