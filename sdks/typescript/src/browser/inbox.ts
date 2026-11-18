import { RelayApiError, RelayConnectionError } from "../core/errors.js";
import { newIdempotencyKey } from "../core/transport.js";
import type { components } from "../generated/subscriber.js";
import {
  RealtimeConnection,
  type InboxCounters,
  type RealtimeEnvelope,
  type RealtimeOptions,
  type RealtimeStatus,
} from "./realtime.js";
import type { RelaySubscriberClient } from "./subscriber.js";
import { TabCoordinator, type BroadcastChannelLike, type LockManagerLike } from "./tabs.js";

/** The state fields of an inbox item the client works with; the full item carries its content too. */
export interface InboxItem {
  readonly id: string;
  readonly state_version: number;
  readonly seen: boolean;
  readonly read: boolean;
  readonly archived: boolean;
  readonly hidden: boolean;
  readonly expired: boolean;
  readonly snoozed_until: string | null;
  readonly sender_type?: InboxSenderType | null;
  readonly approval?: boolean;
  readonly waitpoint?: InboxWaitpoint | null;
  readonly [field: string]: unknown;
}

/** Who produced a notification (C-24, AG-34). */
export type InboxSenderType = NonNullable<components["schemas"]["InboxItem"]["sender_type"]>;

/** The waitpoint of an item awaiting a response (AG-35). */
export type InboxWaitpoint = components["schemas"]["InboxWaitpoint"];

/** A state intent (IN-12). */
export type InboxIntentOp =
  "seen" | "read" | "unread" | "archive" | "unarchive" | "hide" | "snooze" | "unsnooze" | "click";

/** An intent waiting in the offline queue (IN-13). */
export interface QueuedIntent {
  readonly op: InboxIntentOp;
  readonly item_id: string;
  readonly client_seq: number;
  readonly base_state_version?: number;
  readonly snooze_until?: string;
  readonly key: string;
  readonly offline: boolean;
}

/** What the inbox shows. */
export interface InboxSnapshot {
  /** Known items in list order, without hidden and expired ones. */
  readonly items: readonly InboxItem[];
  readonly counters: InboxCounters | null;
  readonly hasMore: boolean;
  readonly realtime: RealtimeStatus | null;
  readonly pending: number;
}

/** Something the user should be told. */
export type InboxNotice =
  | { readonly type: "updated_elsewhere"; readonly itemId: string; readonly op: InboxIntentOp }
  | {
      readonly type: "intent_failed";
      readonly itemId: string;
      readonly op: InboxIntentOp;
      readonly error: unknown;
    };

/** Handle of an undoable action (IN-15). */
export interface UndoHandle {
  /** Cancels the action if it was not sent yet; returns whether it was cancelled. */
  undo(): boolean;
}

/** Key-value storage for the offline queue, such as `localStorage`. */
export interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

/** The parts of `document` the inbox listens to. */
export interface VisibilitySource {
  readonly visibilityState: string;
  addEventListener(type: "visibilitychange", listener: () => void): void;
  removeEventListener(type: "visibilitychange", listener: () => void): void;
}

/** The parts of `window` the inbox listens to for connectivity. */
export interface OnlineSource {
  addEventListener(type: "online", listener: () => void): void;
  removeEventListener(type: "online", listener: () => void): void;
}

/** Options of the inbox client. */
export interface InboxClientOptions {
  readonly client: RelaySubscriberClient;
  /** Realtime options, or false to rely on REST and the foreground sync only. */
  readonly realtime?: false | Partial<Omit<RealtimeOptions, "tokens" | "onEnvelope">>;
  /** Multi-tab coordination (IN-36), or false for one connection per tab. */
  readonly tabs?:
    | false
    | {
        readonly name?: string;
        readonly locks?: LockManagerLike | null;
        readonly createChannel?: ((name: string) => BroadcastChannelLike) | null;
      };
  /** How long a hidden leader keeps its connection, in milliseconds. */
  readonly hiddenCloseMs?: number;
  /** How long an undoable action waits before it is sent, in milliseconds. */
  readonly undoWindowMs?: number;
  readonly pageSize?: number;
  readonly storage?: StorageLike | null;
  readonly storageKey?: string;
  readonly visibility?: VisibilitySource | null;
  readonly online?: OnlineSource | null;
  readonly isOnline?: () => boolean;
  readonly setTimeout?: (callback: () => void, ms: number) => unknown;
  readonly clearTimeout?: (handle: unknown) => void;
}

const reverseOps: ReadonlySet<InboxIntentOp> = new Set(["unread", "unarchive", "unsnooze"]);

function snoozed(item: InboxItem, now: number): boolean {
  return item.snoozed_until !== null && Date.parse(item.snoozed_until) > now;
}

function inTab(item: InboxItem, now: number): boolean {
  return !item.archived && !item.hidden && !item.expired && !snoozed(item, now);
}

function counts(
  item: InboxItem | undefined,
  now: number,
): { unseen: number; unread: number; total: number } {
  if (item === undefined || !inTab(item, now)) return { unseen: 0, unread: 0, total: 0 };
  return { unseen: item.seen ? 0 : 1, unread: item.read ? 0 : 1, total: 1 };
}

/** The local effect of an intent, applied optimistically before the server answers. */
export function applyIntent(item: InboxItem, op: InboxIntentOp, snoozeUntil?: string): InboxItem {
  switch (op) {
    case "seen":
      return { ...item, seen: true };
    case "read":
      return { ...item, read: true, seen: true };
    case "unread":
      return { ...item, read: false };
    case "archive":
      return { ...item, archived: true };
    case "unarchive":
      return { ...item, archived: false };
    case "hide":
      return { ...item, hidden: true };
    case "snooze":
      return { ...item, snoozed_until: snoozeUntil ?? null };
    case "unsnooze":
      return { ...item, snoozed_until: null };
    case "click":
      return item;
  }
}

/**
 * Compacts an offline queue per item (IN-13): only the newest intent of an item stays, and the queue keeps `client_seq` order.
 */
export function compactQueue(intents: readonly QueuedIntent[]): QueuedIntent[] {
  const latest = new Map<string, QueuedIntent>();
  for (const intent of intents) {
    const known = latest.get(intent.item_id);
    if (known === undefined || intent.client_seq > known.client_seq)
      latest.set(intent.item_id, intent);
  }
  return [...latest.values()].sort((a, b) => a.client_seq - b.client_seq);
}

/**
 * Whether a queued intent is still sent (IN-13): monotone intents always are; a reverse intent is dropped when the server has seen a newer state of the item than the one it was based on.
 */
export function stillSendable(intent: QueuedIntent, serverVersion: number | undefined): boolean {
  if (!reverseOps.has(intent.op)) return true;
  if (serverVersion === undefined || intent.base_state_version === undefined) return true;
  return serverVersion <= intent.base_state_version;
}

/**
 * The headless inbox behind the UI components (X-32). It opens the stream before it lists (IN-28), drops envelopes not newer than what it holds (IN-27), sends intents through a per-item compacted offline queue with `client_seq` and accepts a 409 silently (IN-12, IN-13), holds undoable actions in a short client buffer (IN-15), syncs the counters unconditionally when the page comes to the foreground and reports an inconsistency (IN-21), and shares one connection between tabs (IN-36).
 */
export class InboxClient {
  readonly #options: InboxClientOptions;
  readonly #client: RelaySubscriberClient;
  readonly #items = new Map<string, InboxItem>();
  #order: string[] = [];
  #counters: InboxCounters | null = null;
  #cursor: string | null = null;
  #nextCursor: string | null = null;
  #hasMore = false;
  #queue: QueuedIntent[] = [];
  #seq = 0;
  #draining = false;
  #undo = new Map<string, { timer: unknown; previous: InboxItem; intent: QueuedIntent }>();
  #listeners = new Set<(snapshot: InboxSnapshot) => void>();
  #noticeListeners = new Set<(notice: InboxNotice) => void>();
  #realtime: RealtimeConnection | null = null;
  #realtimeStatus: RealtimeStatus | null = null;
  #tabs: TabCoordinator | null = null;
  #buffer: RealtimeEnvelope[] | null = null;
  #hiddenTimer: unknown = null;
  #steppedDown = false;
  #started = false;
  readonly #onVisibility = () => void this.#visibilityChanged();
  readonly #onOnline = () => void this.#drain();

  constructor(options: InboxClientOptions) {
    this.#options = options;
    this.#client = options.client;
  }

  /** Subscribes to snapshots; returns an unsubscribe function. */
  subscribe(listener: (snapshot: InboxSnapshot) => void): () => void {
    this.#listeners.add(listener);
    listener(this.snapshot());
    return () => this.#listeners.delete(listener);
  }

  /** Subscribes to notices such as "updated on another device"; returns an unsubscribe function. */
  onNotice(listener: (notice: InboxNotice) => void): () => void {
    this.#noticeListeners.add(listener);
    return () => this.#noticeListeners.delete(listener);
  }

  /** The current state. */
  snapshot(): InboxSnapshot {
    const items: InboxItem[] = [];
    for (const id of this.#order) {
      const item = this.#items.get(id);
      if (item !== undefined && !item.hidden && !item.expired) items.push(item);
    }
    return {
      items,
      counters: this.#counters,
      hasMore: this.#hasMore,
      realtime: this.#realtimeStatus,
      pending: this.#queue.length + this.#undo.size,
    };
  }

  /** Starts: counters, then the stream, then the first page, then the buffered events, then the offline queue. */
  async start(): Promise<void> {
    if (this.#started) return;
    this.#started = true;
    this.#loadQueue();
    this.#visibility()?.addEventListener("visibilitychange", this.#onVisibility);
    this.#onlineSource()?.addEventListener("online", this.#onOnline);
    await this.syncCounters();
    this.#buffer = [];
    this.#openStream();
    await this.#coldSync();
    const buffered = this.#buffer ?? [];
    this.#buffer = null;
    for (const envelope of buffered) await this.#applyEnvelope(envelope);
    this.#emit();
    await this.#drain();
  }

  /** Stops the stream and the listeners; queued intents stay stored. */
  stop(): void {
    this.#started = false;
    this.#visibility()?.removeEventListener("visibilitychange", this.#onVisibility);
    this.#onlineSource()?.removeEventListener("online", this.#onOnline);
    this.#realtime?.stop();
    this.#realtime = null;
    this.#tabs?.stop();
    this.#tabs = null;
    if (this.#hiddenTimer !== null) this.#clearTimeout(this.#hiddenTimer);
    this.#hiddenTimer = null;
  }

  /** Loads the next page of the list. */
  async loadMore(): Promise<void> {
    if (!this.#hasMore || this.#nextCursor === null) return;
    const page = (await this.#client.call("listMyInboxItems", {
      query: { limit: this.#pageSize(), starting_after: this.#nextCursor },
    } as never)) as unknown as {
      data: InboxItem[];
      has_more: boolean;
      next_cursor: string | null;
    };
    for (const item of page.data) {
      this.#upsert(item);
      if (!this.#order.includes(item.id)) this.#order.push(item.id);
    }
    this.#hasMore = page.has_more;
    this.#nextCursor = page.next_cursor;
    this.#emit();
  }

  /** Reports the item as seen. */
  markSeen(itemId: string): void {
    this.#intent("seen", itemId);
  }

  /** Marks the item read. */
  markRead(itemId: string): void {
    this.#intent("read", itemId);
  }

  /** Marks the item unread. */
  markUnread(itemId: string): void {
    this.#intent("unread", itemId);
  }

  /** Reports a click on the item. */
  click(itemId: string): void {
    this.#intent("click", itemId);
  }

  /** Archives the item; with `undoable` it waits in the undo buffer first. */
  archive(itemId: string, options: { undoable?: boolean } = {}): UndoHandle {
    return this.#intent("archive", itemId, undefined, options.undoable ?? false);
  }

  /** Moves the item back from the archive. */
  unarchive(itemId: string): void {
    this.#intent("unarchive", itemId);
  }

  /** Hides the item for good; with `undoable` it waits in the undo buffer first. */
  hide(itemId: string, options: { undoable?: boolean } = {}): UndoHandle {
    return this.#intent("hide", itemId, undefined, options.undoable ?? false);
  }

  /** Snoozes the item until a time (RFC 3339). */
  snooze(itemId: string, until: string): void {
    this.#intent("snooze", itemId, until);
  }

  /** Ends a snooze. */
  unsnooze(itemId: string): void {
    this.#intent("unsnooze", itemId);
  }

  /** Marks every item read, or every item of a category, in one request (IN-14). */
  async markAllRead(category?: string): Promise<void> {
    const result = (await this.#client.call("markAllMyInboxRead", {
      body: category === undefined ? {} : { category },
    } as never)) as unknown as { counters: InboxCounters };
    for (const [id, item] of this.#items) {
      if (category === undefined || item.category === category)
        this.#items.set(id, { ...item, read: true, seen: true });
    }
    this.#setCounters(result.counters, true);
    this.#emit();
  }

  /**
   * Asks for the counters unconditionally (IN-21) and, when the whole list is loaded and nothing is pending, compares them with the items; a mismatch is reported and the reconciled counters are taken.
   */
  async syncCounters(): Promise<void> {
    const counters = (await this.#client.call("getMyInboxCounters")) as unknown as InboxCounters;
    this.#setCounters(counters, true);
    if (this.#consistencyCheckable() && !this.#consistent()) {
      const result = (await this.#client.call("reportMyInboxInconsistency")) as unknown as {
        counters: InboxCounters;
      };
      this.#setCounters(result.counters, true);
    }
    this.#emit();
  }

  /** Reads the changes since the stream cursor (IN-29); a truncated or invalid cursor falls back to a cold sync. */
  async deltaSync(): Promise<void> {
    if (this.#cursor === null) {
      await this.#coldSync();
      return;
    }
    for (;;) {
      const changes = (await this.#client.call("listMyInboxChanges", {
        query: { since: this.#cursor },
      } as never)) as unknown as {
        changes: { type: string; item_id: string; state_version: number; item: InboxItem }[];
        cursor: string;
        has_more: boolean;
        truncated: boolean;
        resync_required: boolean;
        counters: InboxCounters;
      };
      if (changes.truncated || changes.resync_required) {
        await this.#coldSync();
        return;
      }
      for (const change of changes.changes) {
        const known = this.#items.get(change.item_id);
        if (known !== undefined && change.state_version <= known.state_version) continue;
        const item = {
          ...(known ?? {}),
          ...change.item,
          id: change.item_id,
          state_version: change.state_version,
        } as InboxItem;
        this.#items.set(change.item_id, item);
        if (change.type === "created" && !this.#order.includes(change.item_id))
          this.#order.unshift(change.item_id);
      }
      this.#cursor = changes.cursor;
      this.#setCounters(changes.counters, false);
      if (!changes.has_more) break;
    }
    this.#emit();
  }

  #pageSize(): number {
    return this.#options.pageSize ?? 50;
  }

  #setTimeout(callback: () => void, ms: number): unknown {
    const schedule = this.#options.setTimeout;
    return schedule ? schedule(callback, ms) : globalThis.setTimeout(callback, ms);
  }

  #clearTimeout(handle: unknown): void {
    const cancel = this.#options.clearTimeout;
    if (cancel) cancel(handle);
    else globalThis.clearTimeout(handle as ReturnType<typeof globalThis.setTimeout>);
  }

  #visibility(): VisibilitySource | null {
    if (this.#options.visibility !== undefined) return this.#options.visibility;
    return (globalThis as { document?: VisibilitySource }).document ?? null;
  }

  #onlineSource(): OnlineSource | null {
    if (this.#options.online !== undefined) return this.#options.online;
    return (globalThis as { window?: OnlineSource }).window ?? null;
  }

  #isOnline(): boolean {
    if (this.#options.isOnline) return this.#options.isOnline();
    return (globalThis as { navigator?: { onLine?: boolean } }).navigator?.onLine ?? true;
  }

  #emit(): void {
    const snapshot = this.snapshot();
    for (const listener of this.#listeners) listener(snapshot);
  }

  #notice(notice: InboxNotice): void {
    for (const listener of this.#noticeListeners) listener(notice);
  }

  #setCounters(counters: InboxCounters | undefined, allowEqual: boolean): void {
    if (counters === undefined) return;
    const current = this.#counters;
    if (
      current === null ||
      counters.version > current.version ||
      (allowEqual && counters.version === current.version)
    ) {
      this.#counters = {
        unseen: counters.unseen,
        unread: counters.unread,
        total: counters.total,
        version: counters.version,
      };
    }
  }

  #adjustCounters(before: InboxItem | undefined, after: InboxItem | undefined): void {
    if (this.#counters === null) return;
    const now = Date.now();
    const a = counts(before, now);
    const b = counts(after, now);
    this.#counters = {
      unseen: Math.max(0, this.#counters.unseen + b.unseen - a.unseen),
      unread: Math.max(0, this.#counters.unread + b.unread - a.unread),
      total: Math.max(0, this.#counters.total + b.total - a.total),
      version: this.#counters.version,
    };
  }

  #upsert(item: InboxItem): boolean {
    const known = this.#items.get(item.id);
    if (known !== undefined && item.state_version <= known.state_version) return false;
    this.#items.set(item.id, known === undefined ? item : { ...known, ...item });
    return true;
  }

  #consistencyCheckable(): boolean {
    return (
      this.#counters !== null &&
      this.#order.length > 0 &&
      !this.#hasMore &&
      this.#queue.length === 0 &&
      this.#undo.size === 0
    );
  }

  #consistent(): boolean {
    const now = Date.now();
    let unseen = 0;
    let unread = 0;
    let total = 0;
    for (const item of this.#items.values()) {
      const c = counts(item, now);
      unseen += c.unseen;
      unread += c.unread;
      total += c.total;
    }
    const counters = this.#counters;
    return (
      counters !== null &&
      counters.unseen === unseen &&
      counters.unread === unread &&
      counters.total === total
    );
  }

  async #coldSync(): Promise<void> {
    const page = (await this.#client.call("listMyInboxItems", {
      query: { limit: this.#pageSize() },
    } as never)) as unknown as {
      data: InboxItem[];
      has_more: boolean;
      next_cursor: string | null;
      counters?: InboxCounters;
      cursor?: string;
    };
    this.#items.clear();
    this.#order = [];
    for (const item of page.data) {
      this.#items.set(item.id, item);
      this.#order.push(item.id);
    }
    this.#hasMore = page.has_more;
    this.#nextCursor = page.next_cursor;
    if (page.cursor !== undefined) this.#cursor = page.cursor;
    this.#setCounters(page.counters, true);
    for (const intent of [
      ...this.#queue,
      ...[...this.#undo.values()].map((entry) => entry.intent),
    ]) {
      const item = this.#items.get(intent.item_id);
      if (item !== undefined)
        this.#items.set(item.id, applyIntent(item, intent.op, intent.snooze_until));
    }
    this.#emit();
  }

  #openStream(): void {
    if (this.#options.realtime === false) return;
    const tabs = this.#options.tabs;
    if (tabs === false) {
      this.#startRealtime();
      return;
    }
    this.#tabs = new TabCoordinator({
      name: tabs?.name ?? "esuiss-relay-inbox",
      ...(tabs?.locks === undefined ? {} : { locks: tabs.locks }),
      ...(tabs?.createChannel === undefined ? {} : { createChannel: tabs.createChannel }),
      onLeader: () => this.#startRealtime(),
      onFollower: () => {
        this.#realtime?.stop();
        this.#realtime = null;
      },
      onMessage: (message) => {
        const envelope = (message as { envelope?: RealtimeEnvelope }).envelope;
        if (envelope !== undefined) this.#receive(envelope);
      },
    });
    this.#tabs.start();
  }

  #startRealtime(): void {
    if (this.#realtime !== null) return;
    const options: Partial<Omit<RealtimeOptions, "tokens" | "onEnvelope">> =
      this.#options.realtime === false ? {} : (this.#options.realtime ?? {});
    this.#realtime = new RealtimeConnection({
      baseUrl: this.#client.transport.baseUrl,
      ...options,
      tokens: this.#client.tokens,
      onEnvelope: (envelope) => {
        this.#tabs?.publish({ envelope });
        this.#receive(envelope);
      },
      onStatus: (status) => {
        this.#realtimeStatus = status;
        options.onStatus?.(status);
        this.#emit();
      },
    });
    this.#realtime.start();
  }

  #receive(envelope: RealtimeEnvelope): void {
    if (this.#buffer !== null) {
      this.#buffer.push(envelope);
      return;
    }
    void this.#applyEnvelope(envelope).then(() => this.#emit());
  }

  async #applyEnvelope(envelope: RealtimeEnvelope): Promise<void> {
    this.#setCounters(envelope.counters, false);
    const data = envelope.d;
    switch (envelope.t) {
      case "inbox.item_created": {
        const item = data.item as InboxItem;
        const version = data.state_version as number;
        const known = this.#items.get(item.id);
        if (known !== undefined && version <= known.state_version) return;
        if (data.thin === true) {
          const full = (await this.#client.call("getMyInboxItem", {
            path: { item_id: item.id },
          } as never)) as unknown as InboxItem;
          this.#upsert(full);
        } else {
          this.#upsert({ ...item, state_version: version });
        }
        if (!this.#order.includes(item.id)) this.#order.unshift(item.id);
        return;
      }
      case "inbox.item_updated": {
        const id = data.item_id as string;
        const version = data.state_version as number;
        const known = this.#items.get(id);
        if (known === undefined || version <= known.state_version) return;
        this.#items.set(id, {
          ...known,
          ...(data.changes as Record<string, unknown>),
          state_version: version,
        });
        return;
      }
      case "inbox.items_bulk_updated":
        await this.deltaSync();
        return;
      case "inbox.counters_changed":
        this.#setCounters(data as unknown as InboxCounters, false);
        return;
      case "stream.resync_required":
        await this.#coldSync();
        return;
      default:
        return;
    }
  }

  #intent(op: InboxIntentOp, itemId: string, snoozeUntil?: string, undoable = false): UndoHandle {
    const before = this.#items.get(itemId);
    const intent: QueuedIntent = {
      op,
      item_id: itemId,
      client_seq: ++this.#seq,
      ...(before === undefined ? {} : { base_state_version: before.state_version }),
      ...(snoozeUntil === undefined ? {} : { snooze_until: snoozeUntil }),
      key: newIdempotencyKey(),
      offline: !this.#isOnline(),
    };
    if (before !== undefined) {
      const after = applyIntent(before, op, snoozeUntil);
      this.#items.set(itemId, after);
      this.#adjustCounters(before, after);
    }
    if (!undoable || before === undefined) {
      this.#enqueue(intent);
      this.#emit();
      return { undo: () => false };
    }
    const pending = this.#undo.get(itemId);
    if (pending !== undefined) {
      this.#clearTimeout(pending.timer);
      this.#undo.delete(itemId);
      this.#enqueue(pending.intent);
    }
    const timer = this.#setTimeout(() => {
      this.#undo.delete(itemId);
      this.#enqueue(intent);
      this.#emit();
    }, this.#options.undoWindowMs ?? 5000);
    this.#undo.set(itemId, { timer, previous: before, intent });
    this.#emit();
    return {
      undo: () => {
        const entry = this.#undo.get(itemId);
        if (entry === undefined || entry.intent !== intent) return false;
        this.#clearTimeout(entry.timer);
        this.#undo.delete(itemId);
        const current = this.#items.get(itemId);
        this.#items.set(itemId, entry.previous);
        this.#adjustCounters(current, entry.previous);
        this.#emit();
        return true;
      },
    };
  }

  #enqueue(intent: QueuedIntent): void {
    this.#queue = compactQueue([...this.#queue, intent]);
    this.#saveQueue();
    void this.#drain();
  }

  async #drain(): Promise<void> {
    if (this.#draining) return;
    this.#draining = true;
    try {
      while (this.#queue.length > 0) {
        if (!this.#isOnline()) {
          this.#markOffline();
          return;
        }
        const intent = this.#queue[0] as QueuedIntent;
        const server = this.#items.get(intent.item_id);
        if (!stillSendable(intent, server?.state_version)) {
          this.#remove(intent);
          continue;
        }
        try {
          const result = (await this.#client.call("applyMyInboxIntent", {
            path: { item_id: intent.item_id },
            body: {
              op: intent.op,
              client_seq: intent.client_seq,
              ...(intent.base_state_version === undefined
                ? {}
                : { base_state_version: intent.base_state_version }),
              ...(intent.snooze_until === undefined ? {} : { snooze_until: intent.snooze_until }),
            },
            idempotencyKey: intent.key,
          } as never)) as unknown as { state: InboxItem; counters: InboxCounters };
          this.#remove(intent);
          this.#acceptState(result.state);
          this.#setCounters(result.counters, false);
        } catch (error) {
          if (error instanceof RelayConnectionError) {
            this.#markOffline();
            return;
          }
          this.#remove(intent);
          if (error instanceof RelayApiError && error.code === "inbox_item_conflict") {
            const current = error.problem?.current as InboxItem | undefined;
            if (current !== undefined) this.#acceptState(current);
            if (reverseOps.has(intent.op) && !intent.offline) {
              this.#notice({ type: "updated_elsewhere", itemId: intent.item_id, op: intent.op });
            }
          } else {
            this.#notice({ type: "intent_failed", itemId: intent.item_id, op: intent.op, error });
          }
        }
        this.#emit();
      }
    } finally {
      this.#draining = false;
    }
  }

  #acceptState(state: InboxItem): void {
    const known = this.#items.get(state.id);
    if (known !== undefined && state.state_version < known.state_version) return;
    const merged = { ...(known ?? {}), ...state } as InboxItem;
    const queued =
      this.#queue.find((intent) => intent.item_id === state.id) ?? this.#undo.get(state.id)?.intent;
    this.#items.set(
      state.id,
      queued === undefined ? merged : applyIntent(merged, queued.op, queued.snooze_until),
    );
  }

  #remove(intent: QueuedIntent): void {
    this.#queue = this.#queue.filter((queued) => queued !== intent);
    this.#saveQueue();
  }

  #markOffline(): void {
    this.#queue = this.#queue.map((intent) => ({ ...intent, offline: true }));
    this.#saveQueue();
  }

  #storageKey(): string {
    return this.#options.storageKey ?? "esuiss-relay-inbox-queue";
  }

  #storage(): StorageLike | null {
    if (this.#options.storage !== undefined) return this.#options.storage;
    try {
      return (globalThis as { localStorage?: StorageLike }).localStorage ?? null;
    } catch {
      return null;
    }
  }

  #loadQueue(): void {
    try {
      const raw = this.#storage()?.getItem(this.#storageKey());
      if (raw === null || raw === undefined) return;
      const stored = JSON.parse(raw) as { seq: number; queue: QueuedIntent[] };
      this.#seq = Math.max(this.#seq, stored.seq);
      this.#queue = compactQueue([...stored.queue, ...this.#queue]);
    } catch {
      return;
    }
  }

  #saveQueue(): void {
    try {
      this.#storage()?.setItem(
        this.#storageKey(),
        JSON.stringify({ seq: this.#seq, queue: this.#queue }),
      );
    } catch {
      return;
    }
  }

  async #visibilityChanged(): Promise<void> {
    const visibility = this.#visibility();
    if (visibility === null || !this.#started) return;
    if (visibility.visibilityState === "visible") {
      if (this.#hiddenTimer !== null) this.#clearTimeout(this.#hiddenTimer);
      this.#hiddenTimer = null;
      await this.syncCounters();
      if (this.#steppedDown) {
        this.#steppedDown = false;
        await this.deltaSync();
        if (this.#tabs !== null) this.#tabs.request();
        else this.#startRealtime();
      }
      await this.#drain();
      return;
    }
    if (this.#realtime === null || this.#hiddenTimer !== null) return;
    this.#hiddenTimer = this.#setTimeout(() => {
      this.#hiddenTimer = null;
      this.#steppedDown = true;
      if (this.#tabs !== null) this.#tabs.release();
      this.#realtime?.stop();
      this.#realtime = null;
    }, this.#options.hiddenCloseMs ?? 300_000);
  }
}
