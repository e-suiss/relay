import { RelayError } from '../errors';
import type { RelayHttp } from '../http';
import type { Clock, KeyValueStore, Logger, Random } from '../ports';
import { DurableList } from '../queue';
import type { PushReceipt, PushReceiptRecorded } from '../types';

export type ReceiptKind = PushReceipt['receipt'];

interface ReceiptEntry {
  readonly delivery_id: string;
  readonly receipt: ReceiptKind;
  readonly occurred_at: string;
  readonly idempotency_key: string;
}

const MAX_ENTRIES = 200;

/** Displayed and clicked receipts of pushes, kept on the device until Relay records them. */
export class ReceiptQueue {
  private readonly list: DurableList<ReceiptEntry>;
  private flushing: Promise<void> | null = null;

  constructor(
    private readonly http: RelayHttp,
    store: KeyValueStore,
    private readonly clock: Clock,
    private readonly random: Random,
    private readonly logger: Logger,
  ) {
    this.list = new DurableList(store, 'relay.push.receipts');
  }

  // CH-32
  // X-31
  /** Records that a push was displayed or clicked and tries to send it. */
  async record(deliveryId: string, receipt: ReceiptKind): Promise<void> {
    const entry: ReceiptEntry = {
      delivery_id: deliveryId,
      receipt,
      occurred_at: new Date(this.clock.now()).toISOString(),
      idempotency_key: this.random.uuid(),
    };
    await this.list.update((items) => {
      const duplicate = items.some(
        (item) => item.delivery_id === deliveryId && item.receipt === receipt,
      );
      return duplicate ? items : [...items, entry].slice(-MAX_ENTRIES);
    });
    await this.flush();
  }

  async pending(): Promise<number> {
    return (await this.list.all()).length;
  }

  /** Sends every waiting receipt with its own Idempotency-Key; network failures keep them for the next flush. */
  flush(): Promise<void> {
    this.flushing ??= this.drain().finally(() => {
      this.flushing = null;
    });
    return this.flushing;
  }

  private async drain(): Promise<void> {
    for (const entry of await this.list.all()) {
      try {
        await this.http.request<PushReceiptRecorded>({
          method: 'POST',
          path: '/v1/subscriber/push_receipts',
          body: {
            delivery_id: entry.delivery_id,
            receipt: entry.receipt,
            occurred_at: entry.occurred_at,
          },
          idempotencyKey: entry.idempotency_key,
        });
      } catch (error) {
        if (error instanceof RelayError && error.retryable) return;
        this.logger.warn('relay.receipt.dropped', {
          code: error instanceof RelayError ? error.code : null,
        });
      }
      await this.list.update((items) =>
        items.filter((item) => item.idempotency_key !== entry.idempotency_key),
      );
    }
  }
}
