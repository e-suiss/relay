import { translate, type RelayLocale } from '../i18n';
import type { Clock, KeyValueStore, Logger } from '../ports';
import { DurableList } from '../queue';
import type { InboxCounters } from '../types';
import type { PushAdapter, PushContentSource } from './adapter';
import { parsePush, type NotificationPush, type RelayPush } from './payload';
import type { ReceiptQueue } from './receipts';

export type Presentation = 'display' | 'displayed' | 'none';

export interface ShownNotification {
  readonly deliveryId: string;
  readonly title: string;
  readonly body: string;
  readonly url: string | null;
  readonly contentFree: boolean;
  readonly fetched: boolean;
}

export interface PushHandlerOptions {
  readonly adapter: PushAdapter;
  readonly contentSource: PushContentSource;
  readonly receipts: ReceiptQueue;
  readonly store: KeyValueStore;
  readonly clock: Clock;
  readonly logger: Logger;
  readonly locale: () => RelayLocale;
  readonly syncCounters: () => Promise<InboxCounters | null>;
  readonly channelId?: (push: NotificationPush) => string | null;
  readonly fetchTimeoutMs?: number;
}

interface IndexEntry {
  readonly deliveryId: string;
  readonly notificationId: string;
}

const INDEX_LIMIT = 100;

/** Handles Relay pushes: fetches the content of a content-free push with a generic fallback, records displayed and clicked receipts, and removes a notification read on another device. */
export class PushHandler {
  private readonly index: DurableList<IndexEntry>;

  constructor(private readonly options: PushHandlerOptions) {
    this.index = new DurableList(options.store, 'relay.push.index');
  }

  // CH-33
  // CH-32
  // IN-35
  // IN-38
  /** Handles a received push. `display` shows it through the adapter (Android data messages), `displayed` records that the platform showed it, `none` only reads it. */
  async received(
    payload: unknown,
    presentation: Presentation,
  ): Promise<RelayPush | ShownNotification | null> {
    const push = parsePush(this.options.adapter.platform, payload);
    if (push === null) return null;
    if (push.kind === 'sync') {
      await this.afterSync();
      return push;
    }
    if (push.kind === 'read') {
      await this.removeRead(push.notificationId);
      return push;
    }
    const shown = await this.resolve(push);
    if (presentation === 'display' && this.options.adapter.displayNotification) {
      await this.options.adapter.displayNotification({
        deliveryId: shown.deliveryId,
        title: shown.title,
        body: shown.body,
        url: shown.url,
        channelId: this.options.channelId?.(push) ?? null,
        threadId: push.topic,
      });
      await this.options.receipts.record(push.deliveryId, 'displayed');
    } else if (presentation === 'displayed') {
      await this.options.receipts.record(push.deliveryId, 'displayed');
    }
    return shown;
  }

  // CH-32
  /** Records that the user opened a push and returns where it leads. */
  async opened(payload: unknown): Promise<{ deliveryId: string; url: string | null } | null> {
    const push = parsePush(this.options.adapter.platform, payload);
    if (push?.kind !== 'notification') return null;
    await this.options.receipts.record(push.deliveryId, 'clicked');
    return { deliveryId: push.deliveryId, url: push.url };
  }

  // CH-33 (4)
  private async resolve(push: NotificationPush): Promise<ShownNotification> {
    const locale = this.options.locale();
    if (!push.contentFree) {
      return {
        deliveryId: push.deliveryId,
        title: push.title ?? translate(locale, 'push.fallback.title'),
        body: push.body ?? translate(locale, 'push.fallback.body'),
        url: push.url,
        contentFree: false,
        fetched: false,
      };
    }
    const content = await this.fetchContent(push.deliveryId);
    if (content?.notificationId) await this.remember(push.deliveryId, content.notificationId);
    return {
      deliveryId: push.deliveryId,
      title: content?.title ?? push.title ?? translate(locale, 'push.fallback.title'),
      body: content?.body ?? push.body ?? translate(locale, 'push.fallback.body'),
      url: content?.url ?? null,
      contentFree: true,
      fetched: content !== null,
    };
  }

  private async fetchContent(deliveryId: string) {
    const timeout = this.options.fetchTimeoutMs ?? 8_000;
    let handle: unknown;
    const expired = new Promise<null>((resolve) => {
      handle = this.options.clock.setTimeout(() => {
        resolve(null);
      }, timeout);
    });
    try {
      return await Promise.race([this.options.contentSource.fetch(deliveryId), expired]);
    } catch {
      this.options.logger.debug('relay.push.content_unavailable');
      return null;
    } finally {
      this.options.clock.clearTimeout(handle);
    }
  }

  private async remember(deliveryId: string, notificationId: string): Promise<void> {
    await this.index.update((entries) =>
      [
        ...entries.filter((entry) => entry.deliveryId !== deliveryId),
        { deliveryId, notificationId },
      ].slice(-INDEX_LIMIT),
    );
  }

  // IN-38
  private async removeRead(notificationId: string): Promise<void> {
    const deliveries = new Set(
      (await this.index.all())
        .filter((entry) => entry.notificationId === notificationId)
        .map((entry) => entry.deliveryId),
    );
    if (deliveries.size === 0) {
      await this.afterSync();
      return;
    }
    await this.removeWhere((deliveryId) => deliveries.has(deliveryId));
  }

  // IN-21
  // IN-38
  private async afterSync(): Promise<void> {
    const counters = await this.options.syncCounters().catch(() => null);
    if (counters?.unread === 0) await this.removeWhere(() => true);
  }

  private async removeWhere(match: (deliveryId: string) => boolean): Promise<void> {
    const { adapter } = this.options;
    if (!adapter.getDisplayedNotifications || !adapter.removeDisplayedNotifications) return;
    const shown = await adapter.getDisplayedNotifications();
    const ids = shown.filter((item) => match(item.deliveryId)).map((item) => item.platformId);
    if (ids.length > 0) await adapter.removeDisplayedNotifications(ids);
  }
}
