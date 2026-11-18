import { RelayError } from '../errors';
import type { RelayHttp } from '../http';
import type { KeyValueStore, Logger, Random } from '../ports';
import { DurableList } from '../queue';
import type { InboxIntent, InboxIntentOp, InboxIntentResult, InboxItemState } from '../types';
import type { InboxStore } from './store';

export const REVERSE_OPS: ReadonlySet<InboxIntentOp> = new Set(['unread', 'unarchive', 'unsnooze']);

export interface QueuedIntent {
  readonly item_id: string;
  readonly op: InboxIntentOp;
  readonly client_seq: number;
  readonly base_state_version: number | null;
  readonly snooze_until: string | null;
  readonly idempotency_key: string;
  readonly interactive: boolean;
  readonly session: string;
}

export interface IntentConflict {
  readonly itemId: string;
  readonly op: InboxIntentOp;
  readonly notify: boolean;
}

export interface FlushResult {
  readonly sent: number;
  readonly dropped: number;
  readonly conflicts: readonly IntentConflict[];
  readonly remaining: number;
}

const SEQ_KEY = 'relay.inbox.client_seq';

const isState = (value: unknown): value is InboxItemState =>
  typeof value === 'object' &&
  value !== null &&
  typeof (value as { id?: unknown }).id === 'string' &&
  typeof (value as { state_version?: unknown }).state_version === 'number';

/** The offline queue of inbox intents: ordered by client_seq, compacted to the newest intent per item, sent over REST. */
export class IntentQueue {
  private readonly list: DurableList<QueuedIntent>;
  private flushing: Promise<FlushResult> | null = null;
  private seqChain: Promise<number> = Promise.resolve(-1);

  constructor(
    private readonly http: RelayHttp,
    private readonly store: KeyValueStore,
    private readonly inbox: InboxStore,
    private readonly random: Random,
    private readonly logger: Logger,
    private readonly session: string,
  ) {
    this.list = new DurableList(store, 'relay.inbox.intents');
  }

  // IN-12
  // IN-13
  /** Queues an intent; an older queued intent for the same item is replaced. */
  async enqueue(
    itemId: string,
    op: InboxIntentOp,
    options: { readonly interactive?: boolean; readonly snoozeUntil?: string } = {},
  ): Promise<QueuedIntent> {
    const entry: QueuedIntent = {
      item_id: itemId,
      op,
      client_seq: await this.nextSeq(),
      base_state_version: REVERSE_OPS.has(op) ? (this.inbox.version(itemId) ?? null) : null,
      snooze_until: op === 'snooze' ? (options.snoozeUntil ?? null) : null,
      idempotency_key: this.random.uuid(),
      interactive: options.interactive ?? false,
      session: this.session,
    };
    await this.list.update((items) => [...items.filter((item) => item.item_id !== itemId), entry]);
    this.inbox.optimistic(itemId, op, options.snoozeUntil);
    return entry;
  }

  async pending(): Promise<readonly QueuedIntent[]> {
    return [...(await this.list.all())].sort((a, b) => a.client_seq - b.client_seq);
  }

  /** Sends the queue in client_seq order; a network failure stops the flush and keeps the rest. */
  flush(): Promise<FlushResult> {
    this.flushing ??= this.drain().finally(() => {
      this.flushing = null;
    });
    return this.flushing;
  }

  private async drain(): Promise<FlushResult> {
    let sent = 0;
    let dropped = 0;
    const conflicts: IntentConflict[] = [];
    for (const entry of await this.pending()) {
      const outcome = await this.send(entry);
      if (outcome === 'stop') break;
      if (outcome === 'sent') sent += 1;
      if (outcome === 'dropped') dropped += 1;
      if (typeof outcome === 'object') conflicts.push(outcome);
      await this.list.update((items) =>
        items.filter((item) => item.idempotency_key !== entry.idempotency_key),
      );
    }
    return { sent, dropped, conflicts, remaining: (await this.list.all()).length };
  }

  // IN-12 (4)
  // IN-13 (2)
  private async send(entry: QueuedIntent): Promise<'sent' | 'dropped' | 'stop' | IntentConflict> {
    const known = this.inbox.version(entry.item_id);
    if (
      REVERSE_OPS.has(entry.op) &&
      known !== undefined &&
      entry.base_state_version !== null &&
      known > entry.base_state_version
    ) {
      return 'dropped';
    }
    const body: InboxIntent = {
      op: entry.op,
      client_seq: entry.client_seq,
      ...(entry.base_state_version === null
        ? {}
        : { base_state_version: entry.base_state_version }),
      ...(entry.snooze_until === null ? {} : { snooze_until: entry.snooze_until }),
    };
    try {
      const { body: result } = await this.http.request<InboxIntentResult>({
        method: 'POST',
        path: '/v1/subscriber/inbox/items/{item_id}/intents',
        params: { item_id: entry.item_id },
        body,
        idempotencyKey: entry.idempotency_key,
      });
      this.inbox.applyState(result.state);
      this.inbox.applyCounters(result.counters);
      return 'sent';
    } catch (error) {
      if (!(error instanceof RelayError)) throw error;
      if (error.code === 'inbox_item_conflict') {
        const current = error.problem?.current;
        if (isState(current)) this.inbox.applyState(current);
        return {
          itemId: entry.item_id,
          op: entry.op,
          notify: entry.interactive && entry.session === this.session,
        };
      }
      if (error.retryable) return 'stop';
      this.logger.debug('relay.inbox.intent_dropped', { code: error.code, op: entry.op });
      return 'dropped';
    }
  }

  private nextSeq(): Promise<number> {
    const next = this.seqChain.then(async (current) => {
      let base = current;
      if (base < 0) {
        const stored = Number(await this.store.getItem(SEQ_KEY));
        base = Number.isSafeInteger(stored) && stored >= 0 ? stored : 0;
      }
      const value = base + 1;
      await this.store.setItem(SEQ_KEY, String(value));
      return value;
    });
    this.seqChain = next.catch(() => -1);
    return next;
  }
}
