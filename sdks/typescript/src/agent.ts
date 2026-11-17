import { openThenList, type StreamSubscription } from "./core/stream-sync.js";
import type { RelayServerClient, ServerCallArgs, ServerResult } from "./server.js";

/** A waitpoint as the server API returns it. */
export type Waitpoint = ServerResult<"getWaitpoint">;

/** The body of a new waitpoint. */
export type WaitpointRequest = NonNullable<ServerCallArgs<"createWaitpoint">["body"]>;

/** A mailbox lease as the server API returns it. */
export type MailboxLease = ServerResult<"leaseMailboxRecords">;

/** The answer to an acknowledgement. */
export type MailboxAck = ServerResult<"ackMailboxRecords">;

/** A page of mailbox records read in stream order. */
export type MailboxRecords = ServerResult<"listMailboxRecords">;

/** One mailbox record. */
export type MailboxRecord = MailboxLease extends { records: readonly (infer R)[] } ? R : never;

/** Options of `awaitWaitpoint`. */
export interface AwaitWaitpointOptions {
  readonly signal?: AbortSignal;
  /** First poll interval in milliseconds; it doubles up to `maxIntervalMs`. */
  readonly minIntervalMs?: number;
  readonly maxIntervalMs?: number;
}

/** Options of `followMailbox`. */
export interface FollowMailboxOptions {
  /** Opens the wake-up source (webhook, push or protocol notification); call `push` with each record it carries or with nothing to only wake up. Returns a close function. */
  readonly open: (push: (record?: MailboxRecord) => void) => Promise<() => void> | (() => void);
  readonly onRecord: (record: MailboxRecord) => void;
  /** Position to read after; without it the read starts after the acknowledged position. */
  readonly since?: string;
  readonly limit?: number;
}

const terminal = new Set(["resolved", "expired", "cancelled"]);

interface RecordShape {
  readonly id: string;
  readonly seq: number;
}

interface RecordsShape {
  readonly records: readonly MailboxRecord[];
  readonly cursor: string;
  readonly has_more: boolean;
  readonly resync_required: boolean;
}

/**
 * Agent helpers on the server client (X-30): open and await a waitpoint, read, lease and acknowledge the mailbox, and follow the mailbox with the open-the-stream-then-list-then-deduplicate pattern. A push, webhook or protocol notification only wakes the agent up; records wait in the mailbox (AG-21).
 */
export class RelayAgent {
  readonly client: RelayServerClient;
  readonly #wakers = new Set<() => void>();

  constructor(client: RelayServerClient) {
    this.client = client;
  }

  /** Opens a waitpoint. The Idempotency-Key is the waitpoint's identity, so a retry keeps its deadline. */
  createWaitpoint(body: WaitpointRequest, options: { idempotencyKey?: string } = {}): Promise<Waitpoint> {
    const args = { body, ...options } as unknown as ServerCallArgs<"createWaitpoint">;
    return this.client.call("createWaitpoint", args) as Promise<Waitpoint>;
  }

  /** Reads a waitpoint. */
  getWaitpoint(waitpointId: string, signal?: AbortSignal): Promise<Waitpoint> {
    const args = { path: { waitpoint_id: waitpointId }, signal } as unknown as ServerCallArgs<"getWaitpoint">;
    return this.client.call("getWaitpoint", args);
  }

  /** Wakes every pending `awaitWaitpoint` and mailbox follower now, for example from a webhook hint. */
  wake(): void {
    for (const waker of [...this.#wakers]) waker();
  }

  /** Polls a waitpoint until it is resolved, expired or cancelled; `wake()` polls at once. */
  async awaitWaitpoint(waitpointId: string, options: AwaitWaitpointOptions = {}): Promise<Waitpoint> {
    const min = options.minIntervalMs ?? 1000;
    const max = options.maxIntervalMs ?? 30000;
    let interval = min;
    for (;;) {
      const waitpoint = await this.getWaitpoint(waitpointId, options.signal);
      if (terminal.has((waitpoint as { state: string }).state)) return waitpoint;
      await this.#pause(interval, options.signal);
      interval = Math.min(max, interval * 2);
    }
  }

  /** Reads records after a position in stream order, without taking a lease. */
  readMailbox(options: { since?: string; limit?: number; signal?: AbortSignal } = {}): Promise<MailboxRecords> {
    const query: Record<string, string | number> = {};
    if (options.since !== undefined) query.since = options.since;
    if (options.limit !== undefined) query.limit = options.limit;
    const args = { query, signal: options.signal } as unknown as ServerCallArgs<"listMailboxRecords">;
    return this.client.call("listMailboxRecords", args) as Promise<MailboxRecords>;
  }

  /** Takes up to `max` records with a lease; an unacknowledged record is handed out again (at least once). */
  leaseMailbox(options: { max?: number; idempotencyKey?: string } = {}): Promise<MailboxLease> {
    const body = options.max === undefined ? {} : { max: options.max };
    const args = { body, idempotencyKey: options.idempotencyKey } as unknown as ServerCallArgs<"leaseMailboxRecords">;
    return this.client.call("leaseMailboxRecords", args) as Promise<MailboxLease>;
  }

  /** Acknowledges records of one lease. */
  ackMailbox(leaseId: string, recordIds: readonly string[]): Promise<MailboxAck> {
    const args = { body: { lease_id: leaseId, record_ids: recordIds } } as unknown as ServerCallArgs<"ackMailboxRecords">;
    return this.client.call("ackMailboxRecords", args) as Promise<MailboxAck>;
  }

  /**
   * Follows the mailbox: opens the wake-up source first, then reads the records after `since`, then applies what the source carried, deduplicating by record id (IN-28, AG-21). Every wake-up reads the records after the last position, so a lost hint loses nothing.
   */
  async followMailbox(options: FollowMailboxOptions): Promise<StreamSubscription<MailboxRecord>> {
    let cursor = options.since;
    let reading: Promise<void> = Promise.resolve();
    let deliver: ((record: MailboxRecord) => void) | null = null;

    const readAll = async (): Promise<MailboxRecord[]> => {
      const records: MailboxRecord[] = [];
      for (;;) {
        const page = (await this.readMailbox({
          ...(cursor === undefined ? {} : { since: cursor }),
          ...(options.limit === undefined ? {} : { limit: options.limit }),
        })) as unknown as RecordsShape;
        records.push(...page.records);
        cursor = page.cursor;
        if (!page.has_more) return records;
      }
    };

    const subscription = await openThenList<MailboxRecord>({
      open: (push) =>
        options.open((record) => {
          if (record !== undefined) push(record);
          reading = reading.then(async () => {
            const target = deliver;
            if (target === null) return;
            for (const item of await readAll()) target(item);
          });
        }),
      history: readAll,
      key: (record) => (record as unknown as RecordShape).id,
      version: (record) => (record as unknown as RecordShape).seq,
      onItem: options.onRecord,
    });
    const accept = (record: MailboxRecord) => {
      if (subscription.deduper.accept(record)) options.onRecord(record);
    };
    deliver = accept;
    reading = reading.then(async () => {
      for (const item of await readAll()) accept(item);
    });
    return subscription;
  }

  #pause(ms: number, signal?: AbortSignal): Promise<void> {
    return new Promise((resolve, reject) => {
      if (signal?.aborted) {
        reject(signal.reason);
        return;
      }
      const finish = (error?: unknown) => {
        clearTimeout(timer);
        this.#wakers.delete(waker);
        signal?.removeEventListener("abort", onAbort);
        if (error === undefined) resolve();
        else reject(error);
      };
      const waker = () => finish();
      const onAbort = () => finish(signal?.reason ?? new Error("aborted"));
      const timer = setTimeout(() => finish(), ms);
      this.#wakers.add(waker);
      signal?.addEventListener("abort", onAbort, { once: true });
    });
  }
}
