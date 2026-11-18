import type { InboxItem } from "@esuiss/relay/browser";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { RelayRoot, useInboxState, useRelay } from "../context.js";
import { glyphs, StatusGlyph } from "../icons.js";
import { senderTypeOf } from "../seams.js";
import { safeUrl } from "../url.js";

/** Props of {@link Toaster}. */
export interface ToasterProps {
  /** How long a toast stays when it is neither hovered nor focused, in milliseconds. */
  readonly durationMs?: number;
  /** How many toasts are shown at once. */
  readonly max?: number;
  /** Called when the user opens the item of a toast. */
  readonly onOpen?: (item: InboxItem) => void;
}

/** The ids of new items: unknown before, unread and in the list now. */
export function newItemIds(known: ReadonlySet<string>, items: readonly InboxItem[]): string[] {
  return items.filter((item) => !known.has(item.id) && !item.read && !item.hidden).map((item) => item.id);
}

function ToastView({
  item,
  durationMs,
  onDismiss,
  onOpen,
}: {
  readonly item: InboxItem;
  readonly durationMs: number;
  readonly onDismiss: () => void;
  readonly onOpen: (item: InboxItem) => void;
}): ReactNode {
  const { t } = useRelay();
  const [paused, setPaused] = useState(false);
  useEffect(() => {
    if (paused) return;
    const timer = setTimeout(onDismiss, durationMs);
    return () => clearTimeout(timer);
  }, [paused, durationMs, onDismiss]);
  const title = typeof item.title === "string" && item.title.length > 0 ? item.title : t("inbox.untitled");
  const body = typeof item.body === "string" && item.body.length > 0 ? item.body : null;
  const url = safeUrl(item.url);
  return (
    <div
      className="relay-toast"
      data-testid="relay-toast"
      onMouseEnter={() => setPaused(true)}
      onMouseLeave={() => setPaused(false)}
      onFocus={() => setPaused(true)}
      onBlur={() => setPaused(false)}
    >
      {senderTypeOf(item) === "agent" ? (
        <span className="relay-tag">
          <StatusGlyph glyph={glyphs.agent} />
          {t("inbox.senderAgent")}
        </span>
      ) : null}
      <p className="relay-item-title">{title}</p>
      {body === null ? null : <p className="relay-item-body">{body}</p>}
      <div className="relay-row">
        {url === null ? null : (
          <a className="relay-button relay-button-small" href={url} onClick={() => onOpen(item)}>
            {t("toast.open")}
          </a>
        )}
        <button type="button" className="relay-button relay-button-small" onClick={onDismiss}>
          {t("toast.dismiss")}
        </button>
      </div>
    </div>
  );
}

/**
 * Toasts for notifications that arrive while the page is open (X-32). Items already in the inbox when it loads are not toasted. A toast stays while it is hovered or focused and can always be dismissed (WCAG 2.2.1); it is announced politely.
 */
export function Toaster({ durationMs = 8000, max = 3, onOpen }: ToasterProps): ReactNode {
  const { runtime, t } = useRelay();
  const { snapshot } = useInboxState();
  const known = useRef<Set<string> | null>(null);
  const [toasts, setToasts] = useState<InboxItem[]>([]);
  const items = snapshot?.items;
  const loaded =
    snapshot !== null &&
    snapshot.counters !== null &&
    (snapshot.items.length > 0 || snapshot.counters.total === 0);

  useEffect(() => {
    if (!loaded || items === undefined) return;
    if (known.current === null) {
      known.current = new Set(items.map((item) => item.id));
      return;
    }
    const seen = known.current;
    const fresh = newItemIds(seen, items);
    for (const item of items) seen.add(item.id);
    if (fresh.length === 0) return;
    const freshItems = items.filter((item) => fresh.includes(item.id));
    setToasts((current) => [...freshItems, ...current].slice(0, max));
  }, [loaded, items, max]);

  const dismiss = (id: string) => setToasts((current) => current.filter((item) => item.id !== id));
  const open = (item: InboxItem) => {
    runtime.inbox?.markRead(item.id);
    runtime.inbox?.click(item.id);
    dismiss(item.id);
    onOpen?.(item);
  };

  return (
    <RelayRoot className="relay-inline">
      <div className="relay-toaster" role="region" aria-label={t("toast.region")}>
        <div aria-live="polite" aria-atomic="false">
          {toasts.map((item) => (
            <ToastItem key={item.id} item={item} durationMs={durationMs} onDismiss={dismiss} onOpen={open} />
          ))}
        </div>
      </div>
    </RelayRoot>
  );
}

function ToastItem({
  item,
  durationMs,
  onDismiss,
  onOpen,
}: {
  readonly item: InboxItem;
  readonly durationMs: number;
  readonly onDismiss: (id: string) => void;
  readonly onOpen: (item: InboxItem) => void;
}): ReactNode {
  const [dismiss] = useState(() => () => onDismiss(item.id));
  return <ToastView item={item} durationMs={durationMs} onDismiss={dismiss} onOpen={onOpen} />;
}
