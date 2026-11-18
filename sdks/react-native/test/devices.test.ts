import { describe, expect, it } from 'vitest';
import { DeviceRegistrar } from '../src/push/registrar';
import type { CategoryDefinition } from '../src/push/channels';
import { device, DEVICE_ID, FakePushAdapter } from './fakes';
import { flushPromises, json, testHttp } from './helpers';

const categories: CategoryDefinition[] = [
  { key: 'order_updates', class: 'transactional' },
  { key: 'campaigns', class: 'marketing' },
];

function setup(adapter = new FakePushAdapter()) {
  const harness = testHttp((request) =>
    request.method === 'DELETE' ? json(200, device({ state: 'disabled' })) : json(201, device()),
  );
  const registrar = new DeviceRegistrar(harness.http, adapter, harness.store, harness.logger, {
    categories,
    locale: () => 'tr-TR',
    timezone: () => 'Europe/Istanbul',
  });
  return { ...harness, registrar, adapter };
}

describe('CH-28 CH-30 CH-31 device registration', () => {
  it('CH-28 registers on start with the permission and the Android channel importances', async () => {
    const { registrar, requests, adapter } = setup();
    const registered = await registrar.start();
    expect(registered?.id).toBe(DEVICE_ID);
    expect(adapter.created.map((channel) => channel.id)).toContain(
      'relay.order_updates.time-sensitive',
    );
    const [request] = requests;
    expect(request?.method).toBe('POST');
    expect(request?.path).toBe('/v1/subscriber/devices');
    expect(request?.headers['Idempotency-Key']).toBeDefined();
    expect(request?.body).toMatchObject({
      platform: 'fcm',
      token: 'fcm-token-1',
      app: 'com.example.shop',
      permission: 'granted',
      locale: 'tr-TR',
      timezone: 'Europe/Istanbul',
    });
    const body = request?.body as Record<string, unknown>;
    expect(body.android_channels).toEqual(
      adapter.created.map((channel) => ({ id: channel.id, importance: channel.importance })),
    );
    expect(body).not.toHaveProperty('apns_environment');
    expect(body).not.toHaveProperty('previous_token');
  });

  it('CH-31 sends the previous token when the platform refreshes it', async () => {
    const { registrar, requests, adapter } = setup();
    await registrar.start();
    adapter.refresh('fcm-token-2');
    await flushPromises();
    expect(requests[1]?.body).toMatchObject({
      token: 'fcm-token-2',
      previous_token: 'fcm-token-1',
    });
  });

  it('CH-28 re-registers on foreground only when the permission or channels changed', async () => {
    const { registrar, requests, adapter } = setup();
    await registrar.start();
    await registrar.register('foreground');
    expect(requests).toHaveLength(1);
    adapter.permission = 'denied';
    await registrar.register('foreground');
    expect(requests).toHaveLength(2);
    expect(requests[1]?.body).toMatchObject({ permission: 'denied' });
  });

  it('CH-28 an iOS device carries its APNs environment and no Android channels', async () => {
    const { registrar, requests } = setup(
      new FakePushAdapter('apns', 'com.example.shop', 'sandbox'),
    );
    await registrar.start();
    const body = requests[0]?.body as Record<string, unknown>;
    expect(body.apns_environment).toBe('sandbox');
    expect(body).not.toHaveProperty('android_channels');
  });

  it('CH-29 requests provisional permission only when the starting classes allow it', async () => {
    const adapter = new FakePushAdapter('apns', 'com.example.shop', 'production');
    const { registrar } = setup(adapter);
    await registrar.requestPermission();
    expect(adapter.requested).toEqual([{ provisional: false }]);
  });

  it('CH-28 does nothing before the platform has a token', async () => {
    const adapter = new FakePushAdapter();
    adapter.token = null;
    const { registrar, requests } = setup(adapter);
    expect(await registrar.start()).toBeNull();
    expect(requests).toHaveLength(0);
  });

  it('X-31 sign-out disables the device and forgets the token', async () => {
    const { registrar, requests, store } = setup();
    await registrar.start();
    await registrar.unregister();
    expect(requests[1]?.method).toBe('DELETE');
    expect(requests[1]?.path).toBe(`/v1/subscriber/devices/${DEVICE_ID}`);
    expect(store.entries.size).toBe(0);
  });

  it('CH-65 reads the interruption permissions locally', async () => {
    const { registrar } = setup();
    expect(await registrar.interruptionCapabilities()).toEqual({
      dndAccess: 'denied',
      criticalAlerts: 'unsupported',
      timeSensitive: 'unsupported',
    });
  });

  it('CH-31 the registration log carries no push token', async () => {
    const { registrar, logger } = setup();
    await registrar.start();
    expect(JSON.stringify(logger.events)).not.toContain('fcm-token-1');
  });
});
