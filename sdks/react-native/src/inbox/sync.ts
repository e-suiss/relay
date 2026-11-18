import { RelayError } from '../errors';
import type { RelayHttp } from '../http';
import type { Clock, Logger } from '../ports';
import type { RealtimeConnection } from '../realtime/connection';
import type {
  InboxChanges,
  InboxCounters,
  InboxItem,
  InboxItemList,
  InboxItemState,
  InboxReadAllResult,
  InboxReconciliation,
  RealtimeEnvelope,
} from '../types';
import type { FlushResult, IntentQueue } from './queue';
import type { InboxStore } from './store';

export interface InboxSyncOptions {
  readonly http: RelayHttp;
  readonly store: InboxStore;
  readonly queue: IntentQueue;
  readonly clock: Clock;
  readonly logger: Logger;
  readonly pageSize?: number;
  readonly openWaitMs?: number;
  readonly onConflicts?: (result: FlushResult) => void;
}

const isFull = (item: InboxItem | InboxItemState): item is InboxItem => 'created_at' in item;

/** Keeps the inbox store in step with Relay: cold and delta sync, the realtime buffer, the foreground order and the offline queue. */
export class InboxSync {
  private connection: RealtimeConnection | null = null;
  private syncing = false;
  private buffer: RealtimeEnvelope[] = [];
  private nextPage: string | null = null;
  private hasMore = false;
  private openWaiters: (() => void)[] = [];
  private running: Promise<void> | null = null;

  constructor(private readonly options: InboxSyncOptions) {}

  attach(connection: RealtimeConnection): void {
    this.connection = connection;
  }

  get moreAvailable(): boolean {
    return this.hasMore;
  }

  // IN-35
  // IN-21
  /** The return to the foreground: counters first, then the stream, then delta or cold sync, then the offline queue. */
  async foreground(): Promise<void> {
    await this.refreshCounters().catch(() => null);
    this.connection?.start();
    await this.waitOpen();
    await this.sync();
    await this.flush();
  }

  // IN-35
  /** Going to the background closes the stream. */
  background(): void {
    this.connection?.stop();
  }

  /** Called by the connection when a transport opened. */
  opened(): void {
    for (const resolve of this.openWaiters.splice(0)) resolve();
    if (this.options.store.snapshot().ready) void this.sync().catch(() => undefined);
  }

  // IN-27
  // IN-28
  /** Called by the connection for each envelope; buffered while a sync runs. */
  envelope(envelope: RealtimeEnvelope): void {
    if (this.syncing) {
      this.buffer.push(envelope);
      return;
    }
    this.apply(envelope);
  }

  // IN-21
  /** Fetches the counters; the badge is corrected first on every return to the foreground. */
  async refreshCounters(): Promise<InboxCounters> {
    const { body } = await this.options.http.request<InboxCounters>({
      method: 'GET',
      path: '/v1/subscriber/inbox/counters',
    });
    this.options.store.applyCounters(body);
    return body;
  }

  // IN-29
  /** Delta sync from the stream cursor, or a cold sync when there is none or the delta cannot serve it. */
  sync(): Promise<void> {
    this.running ??= this.runSync().finally(() => {
      this.running = null;
    });
    return this.running;
  }

  /** Loads the next page of the list. */
  async loadMore(): Promise<void> {
    if (!this.hasMore || this.nextPage === null) return;
    const page = await this.list(this.nextPage);
    this.options.store.append(page.data);
  }

  /** Sends the offline queue and reports conflicts the user should see. */
  async flush(): Promise<FlushResult> {
    const result = await this.options.queue.flush();
    if (result.conflicts.length > 0) this.options.onConflicts?.(result);
    return result;
  }

  // IN-14
  // IN-50
  /** Marks every item read, or those of one category. */
  async readAll(category?: string): Promise<InboxReadAllResult> {
    const { body } = await this.options.http.request<InboxReadAllResult>({
      method: 'POST',
      path: '/v1/subscriber/inbox/read_all',
      body: category ? { category } : {},
    });
    this.options.store.applyCounters(body.counters);
    await this.sync();
    return body;
  }

  private async runSync(): Promise<void> {
    this.syncing = true;
    try {
      const cursor = this.options.store.streamCursor;
      if (cursor === null || !this.options.store.snapshot().ready || !(await this.delta(cursor))) {
        await this.cold();
      }
    } finally {
      this.syncing = false;
      const buffered = this.buffer.splice(0);
      for (const envelope of buffered) this.apply(envelope);
    }
  }

  private async cold(): Promise<void> {
    const page = await this.list(null);
    this.options.store.reset(page.data, page.counters ?? null, page.cursor ?? null);
    await this.checkConsistency();
  }

  private async list(startingAfter: string | null): Promise<InboxItemList> {
    const { body } = await this.options.http.request<InboxItemList>({
      method: 'GET',
      path: '/v1/subscriber/inbox/items',
      query: {
        limit: this.options.pageSize ?? 50,
        starting_after: startingAfter ?? undefined,
      },
    });
    this.hasMore = body.has_more;
    this.nextPage = body.next_cursor;
    return body;
  }

  private async delta(since: string): Promise<boolean> {
    let cursor = since;
    for (;;) {
      const { body } = await this.options.http.request<InboxChanges>({
        method: 'GET',
        path: '/v1/subscriber/inbox/changes',
        query: { since: cursor },
      });
      if (body.truncated || body.resync_required) return false;
      for (const change of body.changes) {
        if (isFull(change.item)) this.options.store.applyItem(change.item);
        else this.options.store.applyState(change.item);
      }
      this.options.store.applyCounters(body.counters);
      this.options.store.setCursor(body.cursor);
      if (!body.has_more) return true;
      cursor = body.cursor;
    }
  }

  // IN-21
  private async checkConsistency(): Promise<void> {
    const counters = this.options.store.currentCounters;
    if (this.hasMore || counters === null) return;
    if (this.options.store.listedUnread(this.options.clock.now()) === counters.unread) return;
    try {
      const { body } = await this.options.http.request<InboxReconciliation>({
        method: 'POST',
        path: '/v1/subscriber/inbox/counters/inconsistency',
      });
      this.options.store.applyCounters(body.counters);
    } catch (error) {
      this.options.logger.debug('relay.inbox.reconcile_failed', {
        code: error instanceof RelayError ? error.code : null,
      });
    }
  }

  private apply(envelope: RealtimeEnvelope): void {
    const outcome = this.options.store.applyEnvelope(envelope);
    if (outcome.kind === 'fetch') void this.fetchItem(outcome.itemId);
    if (outcome.kind === 'refresh') void this.sync().catch(() => undefined);
    if (outcome.kind === 'resync') {
      void this.cold().catch(() => undefined);
    }
  }

  private async fetchItem(id: string): Promise<void> {
    try {
      const { body } = await this.options.http.request<InboxItem>({
        method: 'GET',
        path: '/v1/subscriber/inbox/items/{item_id}',
        params: { item_id: id },
      });
      this.options.store.applyItem(body);
    } catch {
      this.options.logger.debug('relay.inbox.item_unavailable');
    }
  }

  private waitOpen(): Promise<void> {
    if (!this.connection || this.connection.current === 'open') return Promise.resolve();
    return new Promise((resolve) => {
      const handle = this.options.clock.setTimeout(() => {
        this.openWaiters = this.openWaiters.filter((waiter) => waiter !== done);
        resolve();
      }, this.options.openWaitMs ?? 3_000);
      const done = () => {
        this.options.clock.clearTimeout(handle);
        resolve();
      };
      this.openWaiters.push(done);
    });
  }
}
