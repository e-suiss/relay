import type { InboxItem, InboxNotice } from "@esuiss/relay/browser";
import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { RelayRoot, useInboxState, useRelay } from "../context.js";
import { Bell } from "./Bell.js";
import { InboxItemView } from "./InboxItemView.js";
import { commitMarkAllRead, pressMarkAllRead, withPendingRead } from "./mark-all-read.js";
import {
  allItems,
  categoriesOf,
  visibleItems,
  type BadgeSource,
  type InboxFilter,
} from "./view.js";

/** A message under the list, with an undo when the action can still be taken back. */
interface Notice {
  readonly text: string;
  readonly undo?: () => void;
}

/** Props of {@link Inbox}. */
export interface InboxProps {
  readonly id?: string;
  /** Heading level of the inbox title; items take the next level. */
  readonly headingLevel?: 2 | 3;
  /** The categories offered as filters, in order; the loaded items' categories otherwise. */
  readonly categories?: readonly string[];
  /** Tags offered as filters, in order (X-16). */
  readonly tags?: readonly string[];
  /** The label of a category key. */
  readonly categoryLabel?: (category: string) => string;
  /** Called when the user opens an item. */
  readonly onItemOpen?: (item: InboxItem) => void;
}

/** The inbox list without its themed root; {@link Inbox} wraps it. */
export function InboxPanel({
  id,
  headingLevel = 2,
  categories,
  tags,
  categoryLabel,
  onItemOpen,
}: InboxProps): ReactNode {
  const { runtime, t, formatTime } = useRelay();
  const { snapshot, error, pendingMarkAllRead } = useInboxState();
  const [filter, setFilter] = useState<InboxFilter>(allItems);
  const [notice, setNotice] = useState<Notice | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const headingId = useId();
  const seenSent = useRef(new Set<string>());
  const inbox = runtime.inbox;
  const label = categoryLabel ?? ((category: string) => category);

  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 60_000);
    return () => clearInterval(timer);
  }, []);

  useEffect(() => {
    if (inbox === null) return;
    const unsubscribe = inbox.onNotice((event: InboxNotice) => {
      setNotice({
        text:
          event.type === "updated_elsewhere"
            ? t("inbox.updatedElsewhere")
            : t("inbox.actionFailed"),
      });
    });
    return () => {
      unsubscribe();
    };
  }, [inbox, t]);

  useEffect(() => {
    if (notice === null) return;
    const timer = setTimeout(
      () => setNotice((current) => (current === notice ? null : current)),
      runtime.undoWindowMs + 1000,
    );
    return () => clearTimeout(timer);
  }, [notice, runtime]);

  const items = snapshot === null ? [] : withPendingRead(snapshot.items, pendingMarkAllRead);
  const shown = visibleItems(items, filter, now);
  const tabs = categories ?? categoriesOf(snapshot?.items ?? []);

  useEffect(() => {
    if (inbox === null) return;
    for (const item of shown) {
      if (!item.seen && !seenSent.current.has(item.id)) {
        seenSent.current.add(item.id);
        inbox.markSeen(item.id);
      }
    }
  }, [inbox, shown]);

  const markAllRead = () => {
    if (
      inbox === null ||
      snapshot === null ||
      pendingMarkAllRead !== null ||
      runtime.subscriber === null
    )
      return;
    const client = runtime.subscriber;
    const pending = pressMarkAllRead(snapshot.items, filter, Date.now());
    if (pending.itemIds.size === 0) return;
    runtime.setPendingMarkAllRead(pending);
    const timer = setTimeout(() => {
      commitMarkAllRead(inbox, client, pending)
        .catch(() => setNotice({ text: t("inbox.actionFailed") }))
        .finally(() => runtime.setPendingMarkAllRead(null));
    }, runtime.undoWindowMs);
    setNotice({
      text: t("inbox.markAllReadDone", { count: pending.itemIds.size }),
      undo: () => {
        clearTimeout(timer);
        runtime.setPendingMarkAllRead(null);
        setNotice({ text: t("inbox.undone") });
      },
    });
  };

  const handlers = {
    onOpen: (item: InboxItem) => {
      if (inbox === null) return;
      if (!item.read) inbox.markRead(item.id);
      inbox.click(item.id);
      onItemOpen?.(item);
    },
    onToggleRead: (item: InboxItem) => {
      if (inbox === null) return;
      if (item.read) inbox.markUnread(item.id);
      else inbox.markRead(item.id);
    },
    onArchive: (item: InboxItem) => {
      if (inbox === null) return;
      const handle = inbox.archive(item.id, { undoable: true });
      setNotice({
        text: t("inbox.archived"),
        undo: () => {
          if (handle.undo()) setNotice({ text: t("inbox.undone") });
        },
      });
    },
    onHide: (item: InboxItem) => {
      if (inbox === null) return;
      const handle = inbox.hide(item.id, { undoable: true });
      setNotice({
        text: t("inbox.hidden"),
        undo: () => {
          if (handle.undo()) setNotice({ text: t("inbox.undone") });
        },
      });
    },
    onSnooze: (item: InboxItem, until: string) => {
      if (inbox === null) return;
      inbox.snooze(item.id, until);
      setNotice({ text: t("inbox.snoozed", { time: formatTime(until) }) });
    },
    onActionClick: (item: InboxItem) => {
      inbox?.click(item.id);
    },
  };

  const Heading = headingLevel === 2 ? "h2" : "h3";
  const loading = snapshot === null || (snapshot.counters === null && snapshot.items.length === 0);
  return (
    <section className="relay-inbox" id={id} aria-labelledby={headingId}>
      <div className="relay-row">
        <Heading className="relay-heading" id={headingId}>
          {t("inbox.title")}
        </Heading>
      </div>
      {tabs.length === 0 ? null : (
        <div className="relay-tabs" role="group" aria-label={t("inbox.tabs")}>
          <button
            type="button"
            className="relay-tab"
            aria-pressed={filter.category === null}
            onClick={() => setFilter({ ...filter, category: null })}
          >
            {t("inbox.tabAll")}
          </button>
          {tabs.map((category) => (
            <button
              key={category}
              type="button"
              className="relay-tab"
              aria-pressed={filter.category === category}
              onClick={() => setFilter({ ...filter, category })}
            >
              {label(category)}
            </button>
          ))}
        </div>
      )}
      {tags === undefined || tags.length === 0 ? null : (
        <div className="relay-tabs" role="group" aria-label={t("inbox.tagTabs")}>
          <button
            type="button"
            className="relay-tab"
            aria-pressed={filter.tag === null}
            onClick={() => setFilter({ ...filter, tag: null })}
          >
            {t("inbox.tabAll")}
          </button>
          {tags.map((tag) => (
            <button
              key={tag}
              type="button"
              className="relay-tab"
              aria-pressed={filter.tag === tag}
              onClick={() => setFilter({ ...filter, tag })}
            >
              {tag}
            </button>
          ))}
        </div>
      )}
      <div className="relay-row">
        <label className="relay-check">
          <input
            type="checkbox"
            checked={filter.unreadOnly}
            onChange={(event) => setFilter({ ...filter, unreadOnly: event.target.checked })}
          />
          {t("inbox.filterUnread")}
        </label>
        <button
          type="button"
          className="relay-button"
          onClick={markAllRead}
          aria-disabled={pendingMarkAllRead !== null}
          data-testid="relay-mark-all-read"
        >
          {t("inbox.markAllRead")}
        </button>
      </div>
      <div role="status" aria-live="polite" data-testid="relay-inbox-notice">
        {notice === null ? null : (
          <div className="relay-notice">
            <span>{notice.text}</span>
            {notice.undo === undefined ? null : (
              <button
                type="button"
                className="relay-button relay-button-small"
                onClick={notice.undo}
              >
                {t("inbox.undo")}
              </button>
            )}
          </div>
        )}
      </div>
      {error === null ? null : (
        <div className="relay-notice" role="alert">
          <span className="relay-error">{t("common.error")}</span>
          <button
            type="button"
            className="relay-button relay-button-small"
            onClick={() => runtime.retryInbox()}
          >
            {t("common.retry")}
          </button>
        </div>
      )}
      {loading && error === null ? (
        <p className="relay-muted" aria-busy="true">
          {t("common.loading")}
        </p>
      ) : shown.length === 0 && error === null ? (
        <p className="relay-muted">
          {filter.category === null && filter.tag === null && !filter.unreadOnly
            ? t("inbox.empty")
            : t("inbox.emptyFiltered")}
        </p>
      ) : (
        <ul className="relay-list" aria-labelledby={headingId}>
          {shown.map((item) => (
            <InboxItemView
              key={item.id}
              item={item}
              categoryLabel={label}
              headingLevel={headingLevel === 2 ? 3 : 4}
              {...handlers}
            />
          ))}
        </ul>
      )}
      {snapshot?.hasMore === true ? (
        <button type="button" className="relay-button" onClick={() => void inbox?.loadMore()}>
          {t("common.loadMore")}
        </button>
      ) : null}
    </section>
  );
}

/**
 * The inbox (X-16, X-17): filters by category and unread, read and unread, archive, delete (the item is hidden and reported as hidden), snooze, a shortcut to each item's category preferences and "mark all as read" for the filtered view, cut off when it is pressed, never archiving, with a short undo and an optimistic badge.
 */
export function Inbox(props: InboxProps): ReactNode {
  return (
    <RelayRoot>
      <InboxPanel {...props} />
    </RelayRoot>
  );
}

/** Props of {@link InboxPopover}. */
export interface InboxPopoverProps extends InboxProps {
  readonly badgeSource?: BadgeSource;
}

/** The bell and the inbox it opens; Escape closes the inbox and returns focus to the bell. */
export function InboxPopover({ badgeSource, ...props }: InboxPopoverProps): ReactNode {
  const [open, setOpen] = useState(false);
  const panelId = useId();
  const rootRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      setOpen(false);
      rootRef.current?.querySelector<HTMLButtonElement>(".relay-bell")?.focus();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [open]);
  return (
    <RelayRoot className="relay-inline">
      <div ref={rootRef}>
        <Bell
          {...(badgeSource === undefined ? {} : { badgeSource })}
          expanded={open}
          onClick={() => setOpen((value) => !value)}
          {...(open ? { controls: panelId } : {})}
          bare
        />
        {open ? <InboxPanel {...props} id={panelId} /> : null}
      </div>
    </RelayRoot>
  );
}
