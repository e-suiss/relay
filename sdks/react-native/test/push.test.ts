import { describe, expect, it } from 'vitest';
import {
  androidChannelId,
  androidChannels,
  provisionalAllowed,
  type CategoryDefinition,
} from '../src/push/channels';
import { parsePush, type PushPlatform } from '../src/push/payload';
import { readJson } from './helpers';

interface ChannelVectors {
  cases: {
    name: string;
    categories: CategoryDefinition[];
    channels: { id: string; category: string; level: string; importance: string; bypass_dnd: boolean }[];
  }[];
  invalid: { name: string; categories: CategoryDefinition[] }[];
}

interface PayloadVectors {
  cases: { name: string; platform: PushPlatform; payload: unknown; expected: Record<string, unknown> }[];
  ignored: { name: string; platform: PushPlatform; payload: unknown }[];
}

const channelVectors = readJson<ChannelVectors>('conformance/sdk/mobile/android_channels.json');
const payloadVectors = readJson<PayloadVectors>('conformance/sdk/mobile/push_payloads.json');

describe('CH-30 CH-65 stable Android channels', () => {
  for (const vector of channelVectors.cases) {
    it(`CH-30 ${vector.name}`, () => {
      const channels = androidChannels(vector.categories).map((channel) => ({
        id: channel.id,
        category: channel.category,
        level: channel.level,
        importance: channel.importance,
        bypass_dnd: channel.bypassDnd,
      }));
      expect(channels).toEqual(vector.channels);
    });
  }

  for (const vector of channelVectors.invalid) {
    it(`CH-30 rejects ${vector.name}`, () => {
      expect(() => androidChannels(vector.categories)).toThrow();
    });
  }

  it('CH-30 matches the server channel naming relay.<category>.<level>', () => {
    expect(androidChannelId('order_updates', 'time-sensitive')).toBe('relay.order_updates.time-sensitive');
  });

  it('CH-29 asks for provisional permission only for marketing and social starts', () => {
    expect(provisionalAllowed(['marketing', 'social'])).toBe(true);
    expect(provisionalAllowed(['marketing', 'transactional'])).toBe(false);
    expect(provisionalAllowed(['security'])).toBe(false);
    expect(provisionalAllowed([])).toBe(false);
  });
});

describe('CH-33 IN-35 IN-38 push payloads', () => {
  for (const vector of payloadVectors.cases) {
    it(`CH-33 ${vector.name}`, () => {
      const push = parsePush(vector.platform, vector.payload);
      expect(push).not.toBeNull();
      const expected = vector.expected;
      if (expected.kind === 'notification') {
        expect(push).toEqual({
          kind: 'notification',
          deliveryId: expected.delivery_id,
          contentFree: expected.content_free,
          topic: expected.topic,
          url: expected.url,
          title: expected.title,
          body: expected.body,
        });
      } else {
        expect(push).toEqual({
          kind: expected.kind,
          counterVersion: expected.counter_version,
          notificationId: expected.notification_id,
        });
      }
    });
  }

  for (const vector of payloadVectors.ignored) {
    it(`CH-33 ignores ${vector.name}`, () => {
      expect(parsePush(vector.platform, vector.payload)).toBeNull();
    });
  }
});
