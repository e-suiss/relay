import { sha256Hex } from './digest';
import { RelayError } from './errors';
import type { RelayHttp } from './http';
import type { Clock, KeyValueStore, Logger, Random, TimerHandle } from './ports';
import { DurableList } from './queue';

/** One displayed notification as Relay receives it: the digest of its id and when it was shown. */
export interface DisplayedNotificationDigest {
  readonly digest: string;
  readonly displayed_at: string;
}

/** Relay's answer to a reported batch of displayed notifications. */
export interface DisplayedNotificationsAccepted {
  readonly object: 'displayed_notifications';
  readonly accepted: number;
  readonly duplicates: number;
}

interface DisplayedBatch {
  readonly idempotency_key: string;
  readonly created_at: number;
  readonly notifications: readonly DisplayedNotificationDigest[];
}

const FLUSH_SIZE = 20;
const FLUSH_INTERVAL_MS = 30_000;
const BATCH_LIMIT = 100;
const MAX_AGE_MS = 24 * 60 * 60 * 1000;

/** The lowercase hex SHA-256 of a notification id; only this digest leaves the device, never the id or any content. */
export function displayedDigest(notificationId: string): string {
  return sha256Hex(notificationId);
}

// OP-54
// OP-95
/** Opt-in duplicate telemetry: queues the digests of displayed notification ids and reports them in batches of at most 100, at 20 queued, every 30 seconds and when the app goes to the background. A failed batch is kept and sent again with the same Idempotency-Key; batches older than 24 hours are dropped. */
export class DisplayedNotificationReporter {
  private readonly pending: DurableList<DisplayedNotificationDigest>;
  private readonly batches: DurableList<DisplayedBatch>;
  private timer: TimerHandle | null = null;
  private flushing: Promise<void> | null = null;

  constructor(
    private readonly http: RelayHttp,
    store: KeyValueStore,
    private readonly clock: Clock,
    private readonly random: Random,
    private readonly logger: Logger,
  ) {
    this.pending = new DurableList(store, 'relay.displayed.pending');
    this.batches = new DurableList(store, 'relay.displayed.batches');
  }

  /** Queues a displayed notification id as its digest; the same id displayed twice is queued twice. */
  async record(notificationId: string): Promise<void> {
    const entry: DisplayedNotificationDigest = {
      digest: displayedDigest(notificationId),
      displayed_at: new Date(this.clock.now()).toISOString(),
    };
    const queued = await this.pending.update((items) => [...items, entry]);
    if (queued.length >= FLUSH_SIZE) await this.flush();
    else this.schedule();
  }

  /** The number of digests waiting on the device. */
  async queued(): Promise<number> {
    const pending = await this.pending.all();
    const batches = await this.batches.all();
    return batches.reduce((sum, batch) => sum + batch.notifications.length, pending.length);
  }

  /** Reports every waiting batch now; a batch Relay could not take stays for the next flush. */
  flush(): Promise<void> {
    this.stop();
    this.flushing ??= this.drain().finally(() => {
      this.flushing = null;
      void this.rearm();
    });
    return this.flushing;
  }

  /** Stops the periodic flush; queued digests stay on the device. */
  stop(): void {
    if (this.timer === null) return;
    this.clock.clearTimeout(this.timer);
    this.timer = null;
  }

  private schedule(): void {
    if (this.timer !== null) return;
    this.timer = this.clock.setTimeout(() => {
      this.timer = null;
      void this.flush().catch(() => undefined);
    }, FLUSH_INTERVAL_MS);
  }

  private async rearm(): Promise<void> {
    if ((await this.queued().catch(() => 0)) > 0) this.schedule();
  }

  private async seal(now: number): Promise<void> {
    const waiting = await this.pending.all();
    if (waiting.length === 0) return;
    const sealed: DisplayedBatch[] = [];
    for (let start = 0; start < waiting.length; start += BATCH_LIMIT) {
      sealed.push({
        idempotency_key: this.random.uuid(),
        created_at: now,
        notifications: waiting.slice(start, start + BATCH_LIMIT),
      });
    }
    await this.batches.update((batches) => [...batches, ...sealed]);
    await this.pending.update((items) => items.slice(waiting.length));
  }

  private async drain(): Promise<void> {
    const now = this.clock.now();
    await this.seal(now);
    const fresh = (batch: DisplayedBatch) => now - batch.created_at < MAX_AGE_MS;
    const stored = await this.batches.all();
    const live = await this.batches.update((batches) => batches.filter(fresh));
    const expired = stored.length - live.length;
    if (expired > 0) this.logger.debug('relay.displayed.expired', { batches: expired });
    for (const batch of live) {
      try {
        await this.http.request<DisplayedNotificationsAccepted>({
          method: 'POST',
          path: '/v1/subscriber/displayed_notifications',
          body: { notifications: batch.notifications },
          idempotencyKey: batch.idempotency_key,
          retry: false,
        });
      } catch (error) {
        if (!(error instanceof RelayError) || error.retryable) return;
        this.logger.warn('relay.displayed.dropped', { code: error.code });
      }
      await this.batches.update((batches) =>
        batches.filter((item) => item.idempotency_key !== batch.idempotency_key),
      );
    }
  }
}
