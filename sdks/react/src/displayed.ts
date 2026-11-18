import { AuthenticationError, type RelaySubscriberClient } from "@esuiss/relay/browser";

/** One displayed notification as Relay receives it: the digest of its identifier and when it was shown. */
export interface DisplayedNotification {
  readonly digest: string;
  readonly displayed_at: string;
}

/** A batch of displayed notifications and the Idempotency-Key it is sent with on every attempt. */
export interface DisplayedBatch {
  readonly key: string;
  readonly createdAt: number;
  readonly notifications: readonly DisplayedNotification[];
}

/** Sends one batch; a rejection keeps the batch for the next flush. */
export type DisplayedSender = (batch: DisplayedBatch) => Promise<void>;

/** Options of {@link DisplayedReporter}; every seam but `send` has a browser default. */
export interface DisplayedReporterOptions {
  readonly send: DisplayedSender;
  readonly now?: () => number;
  readonly newKey?: () => string;
  readonly digest?: (id: string) => Promise<string>;
  /** Starts a one-shot timer and returns its cancel function. */
  readonly setTimer?: (callback: () => void, ms: number) => () => void;
  /** Calls back whenever the page becomes hidden and returns the unsubscribe function. */
  readonly onHidden?: (callback: () => void) => () => void;
}

const batchSize = 20;
const flushIntervalMs = 30_000;
const maxPerRequest = 100;
const maxAgeMs = 86_400_000;

/** The lowercase hex SHA-256 of the UTF-8 bytes of a notification identifier. */
export async function notificationDigest(id: string): Promise<string> {
  const hash = await globalThis.crypto.subtle.digest("SHA-256", new TextEncoder().encode(id));
  return Array.from(new Uint8Array(hash), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function newKey(): string {
  return globalThis.crypto.randomUUID();
}

function timer(callback: () => void, ms: number): () => void {
  const handle = setTimeout(callback, ms);
  return () => clearTimeout(handle);
}

function pageHidden(callback: () => void): () => void {
  if (typeof document === "undefined") return () => undefined;
  const listener = () => {
    if (document.visibilityState === "hidden") callback();
  };
  document.addEventListener("visibilitychange", listener);
  return () => document.removeEventListener("visibilitychange", listener);
}

/** The sender that posts a batch to `/v1/subscriber/displayed_notifications` with the subscriber token and the batch's Idempotency-Key. */
export function apiDisplayedSender(client: RelaySubscriberClient): DisplayedSender {
  return async (batch) => {
    const request = () =>
      client.transport.request<unknown>({
        method: "POST",
        path: "/v1/subscriber/displayed_notifications",
        body: { notifications: batch.notifications },
        idempotency: "required",
        idempotencyKey: batch.key,
      });
    try {
      await request();
    } catch (error) {
      if (!(error instanceof AuthenticationError) || error.code !== "auth_expired_token")
        throw error;
      client.tokens.invalidate();
      await request();
    }
  };
}

/**
 * Queues the digests of displayed notification identifiers and sends them in batches: when 20 are queued, 30 seconds after the last flush and when the page becomes hidden, at most 100 per request. A failed batch is sent again on the next flush with the same Idempotency-Key; batches older than 24 hours are dropped. The identifier itself and the notification's content are never sent.
 */
export class DisplayedReporter {
  readonly #send: DisplayedSender;
  readonly #now: () => number;
  readonly #newKey: () => string;
  readonly #digest: (id: string) => Promise<string>;
  readonly #setTimer: (callback: () => void, ms: number) => () => void;
  readonly #onHidden: (callback: () => void) => () => void;
  #pending: DisplayedNotification[] = [];
  #batches: DisplayedBatch[] = [];
  #hashing: Promise<void> = Promise.resolve();
  #flushing: Promise<void> | null = null;
  #cancelTimer: (() => void) | null = null;
  #stopHidden: (() => void) | null = null;

  constructor(options: DisplayedReporterOptions) {
    this.#send = options.send;
    this.#now = options.now ?? Date.now;
    this.#newKey = options.newKey ?? newKey;
    this.#digest = options.digest ?? notificationDigest;
    this.#setTimer = options.setTimer ?? timer;
    this.#onHidden = options.onHidden ?? pageHidden;
  }

  /** The number of displayed notifications not yet accepted by Relay. */
  get queued(): number {
    return (
      this.#pending.length +
      this.#batches.reduce((total, batch) => total + batch.notifications.length, 0)
    );
  }

  /** Queues one displayed notification identifier; resolves once its digest is queued. A second display of the same identifier is queued again. */
  report(id: string): Promise<void> {
    const displayedAt = new Date(this.#now()).toISOString();
    const queued = this.#hashing.then(async () => {
      const digest = await this.#digest(id);
      this.#pending.push({ digest, displayed_at: displayedAt });
      if (this.#stopHidden === null) this.#stopHidden = this.#onHidden(() => void this.flush());
      if (this.#pending.length >= batchSize) void this.flush();
      else this.#arm();
    });
    this.#hashing = queued.catch(() => undefined);
    return queued;
  }

  /** Sends everything queued now; resolves when done. A failed batch stays queued. */
  flush(): Promise<void> {
    this.#flushing ??= this.#flushOnce();
    return this.#flushing;
  }

  /** Stops the timer and the page visibility listener; queued notifications stay queued. */
  stop(): void {
    this.#cancelTimer?.();
    this.#cancelTimer = null;
    this.#stopHidden?.();
    this.#stopHidden = null;
  }

  async #flushOnce(): Promise<void> {
    try {
      await this.#hashing;
      await this.#drain();
    } finally {
      this.#flushing = null;
      if (this.#pending.length >= batchSize) void this.flush();
      else this.#arm();
    }
  }

  async #drain(): Promise<void> {
    const now = this.#now();
    while (this.#pending.length > 0) {
      this.#batches.push({
        key: this.#newKey(),
        createdAt: now,
        notifications: this.#pending.splice(0, maxPerRequest),
      });
    }
    this.#batches = this.#batches.filter((batch) => now - batch.createdAt < maxAgeMs);
    for (let batch = this.#batches[0]; batch !== undefined; batch = this.#batches[0]) {
      try {
        await this.#send(batch);
      } catch {
        return;
      }
      this.#batches.shift();
    }
  }

  #arm(): void {
    if (this.#cancelTimer !== null) return;
    if (this.#pending.length === 0 && this.#batches.length === 0) return;
    this.#cancelTimer = this.#setTimer(() => {
      this.#cancelTimer = null;
      void this.flush();
    }, flushIntervalMs);
  }
}
