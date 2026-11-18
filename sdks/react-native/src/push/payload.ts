export type PushPlatform = 'apns' | 'fcm' | 'hms';

export interface NotificationPush {
  readonly kind: 'notification';
  readonly deliveryId: string;
  readonly contentFree: boolean;
  readonly topic: string | null;
  readonly url: string | null;
  readonly title: string | null;
  readonly body: string | null;
}

export interface SyncPush {
  readonly kind: 'sync';
  readonly counterVersion: number | null;
  readonly notificationId: null;
}

export interface ReadPush {
  readonly kind: 'read';
  readonly counterVersion: number | null;
  readonly notificationId: string;
}

export type RelayPush = NotificationPush | SyncPush | ReadPush;

const DELIVERY_ID = /^dlv_[0-7][0-9a-hjkmnp-tv-z]{25}$/;
const NOTIFICATION_ID = /^ntf_[0-7][0-9a-hjkmnp-tv-z]{25}$/;

type Json = Readonly<Record<string, unknown>>;

const isObject = (value: unknown): value is Json =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

const text = (value: unknown): string | null =>
  typeof value === 'string' && value !== '' ? value : null;

function counter(value: unknown): number | null | undefined {
  if (value === undefined || value === null) return null;
  if (typeof value === 'number' && Number.isInteger(value) && value >= 0) return value;
  if (typeof value === 'string' && /^\d+$/.test(value)) return Number(value);
  return undefined;
}

function alertText(alert: unknown): { title: string | null; body: string | null } {
  if (typeof alert === 'string') return { title: null, body: text(alert) };
  if (isObject(alert)) return { title: text(alert.title), body: text(alert.body) };
  return { title: null, body: null };
}

function apns(payload: Json): RelayPush | null {
  const relay = payload.relay;
  if (!isObject(relay)) return null;
  const aps = isObject(payload.aps) ? payload.aps : {};
  if (relay.sync === true) {
    const version = counter(relay.counter_version);
    if (version === undefined) return null;
    return { kind: 'sync', counterVersion: version, notificationId: null };
  }
  const id = text(relay.id);
  if (id === null || !DELIVERY_ID.test(id)) return null;
  const onlyId = Object.keys(relay).every((key) => key === 'id');
  const { title, body } = alertText(aps.alert);
  return {
    kind: 'notification',
    deliveryId: id,
    contentFree: aps['mutable-content'] === 1 && onlyId,
    topic: text(relay.topic),
    url: text(relay.url),
    title,
    body,
  };
}

function fcm(payload: Json): RelayPush | null {
  const data = isObject(payload.data) ? payload.data : payload;
  if (data.relay_sync === '1') {
    const version = counter(data.relay_counter_version);
    if (version === undefined) return null;
    const read = data.relay_read;
    if (read === undefined) return { kind: 'sync', counterVersion: version, notificationId: null };
    const notificationId = text(read);
    if (notificationId === null || !NOTIFICATION_ID.test(notificationId)) return null;
    return { kind: 'read', counterVersion: version, notificationId };
  }
  const id = text(data.relay_id);
  if (id === null || !DELIVERY_ID.test(id)) return null;
  const notification = isObject(payload.notification) ? payload.notification : null;
  const neutralTitle = text(data.relay_neutral_title);
  const neutralBody = text(data.relay_neutral_body);
  const contentFree = notification === null && (neutralTitle !== null || neutralBody !== null);
  return {
    kind: 'notification',
    deliveryId: id,
    contentFree,
    topic: text(data.relay_topic),
    url: contentFree ? null : text(data.relay_url),
    title: contentFree ? neutralTitle : text(notification?.title),
    body: contentFree ? neutralBody : text(notification?.body),
  };
}

// CH-33
// IN-35
// IN-38
/** Reads a Relay push: a notification (content-free or not), a sync signal or a read-elsewhere signal; anything else is `null`. */
export function parsePush(platform: PushPlatform, payload: unknown): RelayPush | null {
  if (!isObject(payload)) return null;
  return platform === 'apns' ? apns(payload) : fcm(payload);
}
