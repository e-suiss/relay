import { formatBadge, type InboxCounters, type InboxItem } from "@esuiss/relay/browser";

/** What the badge counts (IN-18): unseen by default, or unread. */
export type BadgeSource = "unseen" | "unread";

/** The filtered view of the inbox list (X-16, X-17). */
export interface InboxFilter {
  readonly category: string | null;
  readonly tag: string | null;
  readonly unreadOnly: boolean;
}

/** The view without a filter. */
export const allItems: InboxFilter = { category: null, tag: null, unreadOnly: false };

function snoozed(item: InboxItem, now: number): boolean {
  return item.snoozed_until !== null && Date.parse(item.snoozed_until) > now;
}

/** Whether an item is in the inbox tab: neither archived, hidden, expired nor snoozed. */
export function inInboxTab(item: InboxItem, now: number): boolean {
  return !item.archived && !item.hidden && !item.expired && !snoozed(item, now);
}

/** Whether an item belongs to a filtered view, read state aside. */
export function inScope(item: InboxItem, filter: InboxFilter, now: number): boolean {
  if (!inInboxTab(item, now)) return false;
  if (filter.category !== null && item.category !== filter.category) return false;
  if (filter.tag !== null) {
    const tags = Array.isArray(item.tags) ? (item.tags as unknown[]) : [];
    if (!tags.includes(filter.tag)) return false;
  }
  return true;
}

/** The items of a filtered view, in list order. */
export function visibleItems(
  items: readonly InboxItem[],
  filter: InboxFilter,
  now: number,
): InboxItem[] {
  return items.filter((item) => inScope(item, filter, now) && (!filter.unreadOnly || !item.read));
}

/** The categories the loaded items carry, sorted. */
export function categoriesOf(items: readonly InboxItem[]): string[] {
  const categories = new Set<string>();
  for (const item of items) {
    if (typeof item.category === "string" && item.category.length > 0) categories.add(item.category);
  }
  return [...categories].sort();
}

/**
 * The badge number (IN-19, X-17): the server's absolute counter, lowered at once for items the user just marked read whose request waits in the undo buffer.
 */
export function badgeCount(
  counters: InboxCounters | null,
  source: BadgeSource,
  pendingRead: readonly InboxItem[] = [],
): number {
  if (counters === null) return 0;
  const lowered = pendingRead.filter((item) => (source === "unseen" ? !item.seen : !item.read)).length;
  return Math.max(0, counters[source] - lowered);
}

/** The badge text (IN-20): the number, capped at `99+`, or empty when there is nothing to count. */
export function badgeText(count: number): string {
  return count > 0 ? formatBadge(count) : "";
}

/** The three snooze choices (X-16) relative to a moment: in an hour, tomorrow at 09:00, next Monday at 09:00. */
export function snoozeTimes(now: Date): { hour: string; tomorrow: string; week: string } {
  const hour = new Date(now.getTime() + 3_600_000);
  const tomorrow = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, 9, 0, 0, 0);
  const daysToMonday = ((8 - now.getDay()) % 7) || 7;
  const week = new Date(now.getFullYear(), now.getMonth(), now.getDate() + daysToMonday, 9, 0, 0, 0);
  return { hour: hour.toISOString(), tomorrow: tomorrow.toISOString(), week: week.toISOString() };
}
