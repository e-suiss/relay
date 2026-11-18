import type {
  DisplayedNotification,
  InterruptionCapabilities,
  LocalNotification,
  PushAdapter,
} from '../src/push/adapter';
import type { AndroidChannelSpec } from '../src/push/channels';
import type { PushPlatform } from '../src/push/payload';
import type { AndroidChannel, DevicePermission } from '../src/types';

export const DEVICE_ID = 'dev_01j9zq3k4m5n6p7q8r9s0t1v2w';

export function device(overrides: Record<string, unknown> = {}) {
  return {
    object: 'device',
    id: DEVICE_ID,
    subscriber_id: 'sub_01j9zq3k4m5n6p7q8r9s0t1v2w',
    platform: 'fcm',
    app: 'com.example.shop',
    token_fingerprint: 'aaaabbbbccccdddd',
    apns_environment: null,
    permission: 'granted',
    android_channels: [],
    locale: null,
    timezone: null,
    state: 'active',
    disabled_reason: null,
    registered_at: '2026-11-18T09:00:00Z',
    last_seen_at: '2026-11-18T09:00:00Z',
    deleted_at: null,
    created_at: '2026-11-18T09:00:00Z',
    updated_at: '2026-11-18T09:00:00Z',
    ...overrides,
  };
}

export class FakePushAdapter implements PushAdapter {
  token: string | null = 'fcm-token-1';
  permission: DevicePermission = 'granted';
  created: AndroidChannelSpec[] = [];
  displayed: (LocalNotification & { platformId: string })[] = [];
  removed: string[] = [];
  requested: { provisional: boolean }[] = [];
  interruption: InterruptionCapabilities | Error = {
    dndAccess: 'denied',
    criticalAlerts: 'unsupported',
    timeSensitive: 'unsupported',
  };
  private listeners: ((token: string) => void)[] = [];

  constructor(
    readonly platform: PushPlatform = 'fcm',
    readonly app = 'com.example.shop',
    readonly apnsEnvironment?: 'production' | 'sandbox',
  ) {}

  getToken() {
    return Promise.resolve(this.token);
  }

  onTokenRefresh(listener: (token: string) => void) {
    this.listeners.push(listener);
    return () => {
      this.listeners = this.listeners.filter((item) => item !== listener);
    };
  }

  refresh(token: string) {
    this.token = token;
    for (const listener of this.listeners) listener(token);
  }

  getPermission() {
    return Promise.resolve(this.permission);
  }

  requestPermission(options: { readonly provisional: boolean }) {
    this.requested.push({ provisional: options.provisional });
    this.permission = options.provisional ? 'provisional' : 'granted';
    return Promise.resolve(this.permission);
  }

  createAndroidChannels(channels: readonly AndroidChannelSpec[]) {
    this.created = [...channels];
    return Promise.resolve();
  }

  getAndroidChannels(): Promise<readonly AndroidChannel[]> {
    return Promise.resolve(
      this.created.map((channel) => ({ id: channel.id, importance: channel.importance })),
    );
  }

  getInterruptionCapabilities(): Promise<InterruptionCapabilities> {
    return this.interruption instanceof Error
      ? Promise.reject(this.interruption)
      : Promise.resolve(this.interruption);
  }

  displayNotification(notification: LocalNotification) {
    const platformId = `n${String(this.displayed.length + 1)}`;
    this.displayed.push({ ...notification, platformId });
    return Promise.resolve(platformId);
  }

  getDisplayedNotifications(): Promise<readonly DisplayedNotification[]> {
    return Promise.resolve(
      this.displayed
        .filter((item) => !this.removed.includes(item.platformId))
        .map((item) => ({ deliveryId: item.deliveryId, platformId: item.platformId })),
    );
  }

  removeDisplayedNotifications(platformIds: readonly string[]) {
    this.removed.push(...platformIds);
    return Promise.resolve();
  }
}
