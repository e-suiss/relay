import type { InboxClient, InboxItem, RelaySubscriberClient } from "@esuiss/relay/browser";
import { inScope, type InboxFilter } from "./view.js";

/** A pressed "mark all as read" waiting in the undo buffer (X-17, IN-15). */
export interface PendingMarkAllRead {
  /** When the button was pressed: the cut-off of the action. */
  readonly pressedAt: number;
  readonly filter: InboxFilter;
  /** The unread items of the view at the press, shown read at once. */
  readonly itemIds: ReadonlySet<string>;
  /** Every item known at the press, so items that arrive later stay unread. */
  readonly knownIds: ReadonlySet<string>;
}

/** Captures the view at the press: its unread items and every item known at that moment. */
export function pressMarkAllRead(
  items: readonly InboxItem[],
  filter: InboxFilter,
  now: number,
): PendingMarkAllRead {
  return {
    pressedAt: now,
    filter,
    itemIds: new Set(items.filter((item) => inScope(item, filter, now) && !item.read).map((item) => item.id)),
    knownIds: new Set(items.map((item) => item.id)),
  };
}

/** Shows the items of a pending action as read. */
export function withPendingRead(
  items: readonly InboxItem[],
  pending: PendingMarkAllRead | null,
): InboxItem[] {
  if (pending === null) return [...items];
  return items.map((item) => (pending.itemIds.has(item.id) ? { ...item, read: true, seen: true } : item));
}

/** The items of a pending action as they were before it, for the optimistic badge. */
export function pendingReadItems(
  items: readonly InboxItem[],
  pending: PendingMarkAllRead | null,
): InboxItem[] {
  if (pending === null) return [];
  return items.filter((item) => pending.itemIds.has(item.id) && !item.read);
}

interface BulkOperation {
  readonly id: string;
  readonly state: "running" | "completed";
  readonly updated: number;
}

/** Waits between progress reads of a bulk action. */
export type Wait = (ms: number) => Promise<void>;

const wait: Wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Sends a pending "mark all as read" once its undo window ended (X-17). The whole inbox or one category goes through the mark-all-read operation, a tag view through a bulk read whose progress is followed. Nothing is archived. Items that arrived after the press are set unread again, so the cut-off is the moment the button was pressed. Returns how many items were marked read.
 */
export async function commitMarkAllRead(
  inbox: InboxClient,
  client: RelaySubscriberClient,
  pending: PendingMarkAllRead,
  options: { readonly wait?: Wait; readonly now?: () => number } = {},
): Promise<number> {
  const now = options.now ?? Date.now;
  const late = inbox
    .snapshot()
    .items.filter(
      (item) => !pending.knownIds.has(item.id) && !item.read && inScope(item, pending.filter, now()),
    )
    .map((item) => item.id);
  let updated: number;
  if (pending.filter.tag === null) {
    const before = inbox.snapshot().counters?.unread ?? null;
    await inbox.markAllRead(pending.filter.category ?? undefined);
    const after = inbox.snapshot().counters?.unread ?? null;
    updated = before !== null && after !== null ? Math.max(0, before - after) : pending.itemIds.size;
  } else {
    const filter = {
      status: "inbox",
      tag: pending.filter.tag,
      ...(pending.filter.category === null ? {} : { category: pending.filter.category }),
    };
    let operation = (await client.call("startMyInboxBulk", {
      body: { action: "read", filter },
    } as never)) as unknown as BulkOperation;
    const sleep = options.wait ?? wait;
    while (operation.state !== "completed") {
      await sleep(500);
      operation = (await client.call("getMyInboxBulk", {
        path: { bulk_id: operation.id },
      } as never)) as unknown as BulkOperation;
    }
    updated = operation.updated;
  }
  if (late.length > 0) {
    await inbox.deltaSync();
    for (const id of late) {
      if (inbox.snapshot().items.find((item) => item.id === id)?.read === true) inbox.markUnread(id);
    }
  } else if (pending.filter.tag !== null) {
    await inbox.deltaSync();
  }
  return updated;
}
