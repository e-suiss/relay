import type {
  InboxCounters,
  InboxItem,
  InboxItemState,
  InboxIntentOp,
  RealtimeEnvelope,
} from '../types';

export type InboxTab = 'inbox' | 'unread' | 'archived' | 'snoozed' | 'all';

export interface InboxSnapshot {
  readonly items: readonly InboxItem[];
  readonly counters: InboxCounters | null;
  readonly cursor: string | null;
  readonly ready: boolean;
}

export type EnvelopeOutcome =
  | { readonly kind: 'applied' }
  | { readonly kind: 'ignored' }
  | { readonly kind: 'fetch'; readonly itemId: string }
  | { readonly kind: 'refresh' }
  | { readonly kind: 'resync' };

type StateFields = Partial<Omit<InboxItemState, 'id' | 'state_version'>>;

const STATE_KEYS = [
  'seen',
  'read',
  'archived',
  'hidden',
  'expired',
  'snoozed_until',
  'seen_at',
  'read_at',
  'archived_at',
] as const;

const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

function stateFields(source: Readonly<Record<string, unknown>>): StateFields {
  const fields: Record<string, unknown> = {};
  for (const key of STATE_KEYS) {
    if (key in source) fields[key] = source[key];
  }
  return fields;
}

/** Whether an item belongs to a tab at `now`. */
export function inTab(item: InboxItem, tab: InboxTab, now: number): boolean {
  if (item.hidden || item.expired) return false;
  const snoozed = item.snoozed_until !== null && Date.parse(item.snoozed_until) > now;
  switch (tab) {
    case 'inbox':
      return !item.archived && !snoozed;
    case 'unread':
      return !item.read && !item.archived && !snoozed;
    case 'archived':
      return item.archived;
    case 'snoozed':
      return snoozed;
    case 'all':
      return true;
  }
}

const OPTIMISTIC: Partial<Record<InboxIntentOp, StateFields>> = {
  seen: { seen: true },
  read: { seen: true, read: true },
  unread: { read: false },
  archive: { archived: true },
  unarchive: { archived: false },
  hide: { hidden: true },
  unsnooze: { snoozed_until: null },
};

/** The client copy of the inbox: items by id with their state_version, counters with their version. An event whose version is not newer than the known one is dropped. */
export class InboxStore {
  private readonly items = new Map<string, InboxItem>();
  private readonly versions = new Map<string, number>();
  private counters: InboxCounters | null = null;
  private cursor: string | null = null;
  private ready = false;
  private readonly listeners = new Set<(snapshot: InboxSnapshot) => void>();
  private cached: InboxSnapshot | null = null;

  subscribe(listener: (snapshot: InboxSnapshot) => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  snapshot(): InboxSnapshot {
    this.cached ??= {
      items: [...this.items.values()].sort((a, b) =>
        a.last_activity_at < b.last_activity_at
          ? 1
          : a.last_activity_at > b.last_activity_at
            ? -1
            : 0,
      ),
      counters: this.counters,
      cursor: this.cursor,
      ready: this.ready,
    };
    return this.cached;
  }

  item(id: string): InboxItem | undefined {
    return this.items.get(id);
  }

  version(id: string): number | undefined {
    return this.versions.get(id);
  }

  get streamCursor(): string | null {
    return this.cursor;
  }

  get currentCounters(): InboxCounters | null {
    return this.counters;
  }

  // IN-28
  // IN-29
  /** Replaces the list with a cold sync page, keeping newer versions already seen on the stream. */
  reset(items: readonly InboxItem[], counters: InboxCounters | null, cursor: string | null): void {
    const known = new Map(this.versions);
    this.items.clear();
    for (const item of items) {
      const seen = known.get(item.id);
      if (seen !== undefined && seen > item.state_version) continue;
      this.items.set(item.id, item);
      this.versions.set(item.id, item.state_version);
    }
    this.setCounters(counters);
    if (cursor !== null) this.cursor = cursor;
    this.ready = true;
    this.emit();
  }

  /** Appends a later page of the list. */
  append(items: readonly InboxItem[]): void {
    for (const item of items) this.putItem(item);
    this.emit();
  }

  // IN-27
  /** Applies a full item if its state_version is newer. */
  applyItem(item: InboxItem): boolean {
    const changed = this.putItem(item);
    if (changed) this.emit();
    return changed;
  }

  // IN-13
  /** Applies a server state (an intent answer or a 409's current state) if newer. */
  applyState(state: InboxItemState): boolean {
    const known = this.versions.get(state.id);
    if (known !== undefined && known >= state.state_version) return false;
    this.versions.set(state.id, state.state_version);
    const item = this.items.get(state.id);
    if (item) this.mergeState(item, { ...stateFields(state), state_version: state.state_version });
    this.emit();
    return true;
  }

  // IN-19
  // IN-27
  /** Applies counters if their version is newer. */
  applyCounters(counters: InboxCounters | null | undefined): boolean {
    const changed = this.setCounters(counters ?? null);
    if (changed) this.emit();
    return changed;
  }

  /** Moves the stream cursor forward. */
  setCursor(cursor: string | null | undefined): void {
    if (cursor) this.cursor = cursor;
  }

  // IN-26
  // IN-27
  /** Applies one realtime envelope and says what the sync engine must do next. */
  applyEnvelope(envelope: RealtimeEnvelope): EnvelopeOutcome {
    this.setCursor(envelope.id);
    const countersChanged = this.setCounters({ object: 'inbox_counters', ...envelope.counters });
    const d: Record<string, unknown> = isObject(envelope.d) ? envelope.d : {};
    let outcome: EnvelopeOutcome = { kind: countersChanged ? 'applied' : 'ignored' };
    switch (envelope.t) {
      case 'inbox.item_created': {
        const item = d.item;
        if (!isObject(item) || typeof item.id !== 'string') break;
        if (d.thin === true) {
          const known = this.versions.get(item.id);
          const version = typeof d.state_version === 'number' ? d.state_version : 0;
          outcome =
            known !== undefined && known >= version ? outcome : { kind: 'fetch', itemId: item.id };
        } else if (this.putItem(item as unknown as InboxItem)) {
          outcome = { kind: 'applied' };
        }
        break;
      }
      case 'inbox.item_updated': {
        const id = d.item_id;
        const version = d.state_version;
        if (typeof id !== 'string' || typeof version !== 'number') break;
        const known = this.versions.get(id);
        if (known !== undefined && known >= version) break;
        this.versions.set(id, version);
        const item = this.items.get(id);
        const changes = isObject(d.changes) ? stateFields(d.changes) : {};
        if (item) {
          this.mergeState(item, { ...changes, state_version: version });
          outcome = { kind: 'applied' };
        } else {
          outcome = { kind: 'fetch', itemId: id };
        }
        break;
      }
      case 'inbox.items_bulk_updated':
        outcome = { kind: 'refresh' };
        break;
      case 'stream.resync_required':
        outcome = { kind: 'resync' };
        break;
      case 'inbox.counters_changed':
        if (this.setCounters({ object: 'inbox_counters', ...(d as Omit<InboxCounters, 'object'>) }))
          outcome = { kind: 'applied' };
        break;
      default:
        break;
    }
    this.emit();
    return outcome;
  }

  /** Applies the visible effect of an intent before the server answers. */
  optimistic(itemId: string, op: InboxIntentOp, snoozeUntil?: string): void {
    const item = this.items.get(itemId);
    if (!item) return;
    const fields: StateFields =
      op === 'snooze' ? { snoozed_until: snoozeUntil ?? null } : (OPTIMISTIC[op] ?? {});
    this.mergeState(item, fields);
    this.emit();
  }

  /** The unread count of the list when it is complete, for the consistency check. */
  listedUnread(now: number): number {
    let unread = 0;
    for (const item of this.items.values()) if (inTab(item, 'unread', now)) unread += 1;
    return unread;
  }

  clear(): void {
    this.items.clear();
    this.versions.clear();
    this.counters = null;
    this.cursor = null;
    this.ready = false;
    this.emit();
  }

  private putItem(item: InboxItem): boolean {
    const known = this.versions.get(item.id);
    if (known !== undefined && known >= item.state_version) return false;
    this.versions.set(item.id, item.state_version);
    if (item.hidden || item.expired) this.items.delete(item.id);
    else this.items.set(item.id, item);
    return true;
  }

  private mergeState(item: InboxItem, fields: StateFields & { state_version?: number }): void {
    const merged = { ...item, ...fields } as InboxItem;
    if (merged.hidden || merged.expired) this.items.delete(item.id);
    else this.items.set(item.id, merged);
  }

  private setCounters(counters: InboxCounters | null): boolean {
    if (counters === null) return false;
    if (this.counters !== null && this.counters.version >= counters.version) return false;
    this.counters = counters;
    return true;
  }

  private emit(): void {
    this.cached = null;
    const snapshot = this.snapshot();
    for (const listener of this.listeners) listener(snapshot);
  }
}
