import type { InboxItem } from "@esuiss/relay/browser";
import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { usePreferenceShortcut, useRelay } from "../context.js";
import { glyphs, StatusGlyph } from "../icons.js";
import { isApprovalItem, senderTypeOf, waitpointOf, type WaitpointResponderView, type WaitpointStatus, type WaitpointView } from "../seams.js";
import { onOrigin, safeUrl } from "../url.js";
import { snoozeTimes } from "./view.js";

/** What an item asks the list to do. */
export interface InboxItemHandlers {
  readonly onOpen: (item: InboxItem) => void;
  readonly onToggleRead: (item: InboxItem) => void;
  readonly onArchive: (item: InboxItem) => void;
  readonly onHide: (item: InboxItem) => void;
  readonly onSnooze: (item: InboxItem, until: string) => void;
  readonly onActionClick: (item: InboxItem) => void;
}

/** Props of {@link InboxItemView}. */
export interface InboxItemViewProps extends InboxItemHandlers {
  readonly item: InboxItem;
  readonly categoryLabel: (category: string) => string;
  readonly headingLevel: 3 | 4;
}

function text(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

interface Receipt {
  readonly status: "processing" | "responded" | "not_awaited";
  readonly responder?: WaitpointResponderView;
  readonly responded_at?: string;
}

function WaitpointPanel({ waitpoint }: { readonly waitpoint: WaitpointView }): ReactNode {
  const { runtime, t, formatTime } = useRelay();
  const [receipt, setReceipt] = useState<Receipt | null>(null);
  const [failed, setFailed] = useState(false);
  const status: WaitpointStatus = receipt?.status ?? waitpoint.status;
  const responder = receipt?.responder ?? waitpoint.responder;
  const respondedAt = receipt?.responded_at ?? waitpoint.responded_at;
  const respond = (value: unknown) => {
    const client = runtime.subscriber;
    if (client === null || waitpoint.subject_digest === null) return;
    setFailed(false);
    setReceipt({ status: "processing" });
    client
      .call("respondToMyWaitpoint", {
        path: { waitpoint_id: waitpoint.id },
        body: { response: value, subject_digest: waitpoint.subject_digest },
      } as never)
      .then((result) => setReceipt(result as unknown as Receipt))
      .catch(() => {
        setReceipt(null);
        setFailed(true);
      });
  };
  const who = (view: WaitpointResponderView | null): string => {
    if (view === null) return t("inbox.whoSomeone");
    if (view.kind === "agent") return t("inbox.whoAgent");
    return view.external_id ?? t("inbox.whoYou");
  };
  let line: ReactNode;
  switch (status) {
    case "processing":
      line = (
        <span className="relay-status">
          <StatusGlyph glyph={glyphs.pending} />
          {t("inbox.processing")}
        </span>
      );
      break;
    case "responded":
      line = (
        <span className="relay-status">
          <StatusGlyph glyph={glyphs.done} />
          {t("inbox.answeredBy", { who: who(responder), when: respondedAt === null ? "" : formatTime(respondedAt) })}
        </span>
      );
      break;
    case "not_awaited":
      line = (
        <span className="relay-status">
          <StatusGlyph glyph={glyphs.stopped} />
          {t("inbox.notAwaited")}
        </span>
      );
      break;
    default:
      line = (
        <span className="relay-status">
          <StatusGlyph glyph={glyphs.awaiting} />
          {t("inbox.awaiting")}
        </span>
      );
  }
  return (
    <div className="relay-stack" data-testid="relay-waitpoint">
      <div aria-live="polite">{line}</div>
      {status === "awaiting" && waitpoint.kind === "response" && waitpoint.subject_digest !== null ? (
        <div className="relay-row">
          {waitpoint.options.map((option) => (
            <button
              key={option.label}
              type="button"
              className="relay-button relay-button-small"
              onClick={() => respond(option.value)}
            >
              {option.label}
            </button>
          ))}
        </div>
      ) : null}
      {failed ? <p className="relay-error">{t("inbox.actionFailed")}</p> : null}
    </div>
  );
}

function SnoozeMenu({ item, onSnooze }: { readonly item: InboxItem; readonly onSnooze: (item: InboxItem, until: string) => void }): ReactNode {
  const { t } = useRelay();
  const [open, setOpen] = useState(false);
  const menuId = useId();
  const buttonRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (!open) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setOpen(false);
        buttonRef.current?.focus();
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [open]);
  const choose = (until: string) => {
    setOpen(false);
    onSnooze(item, until);
    buttonRef.current?.focus();
  };
  return (
    <div className="relay-menu">
      <button
        ref={buttonRef}
        type="button"
        className="relay-button relay-button-small"
        aria-expanded={open}
        {...(open ? { "aria-controls": menuId } : {})}
        onClick={() => setOpen((value) => !value)}
      >
        {t("inbox.snooze")}
      </button>
      {open ? (
        <ul className="relay-menu-list" id={menuId}>
          {(["hour", "tomorrow", "week"] as const).map((choice) => (
            <li key={choice}>
              <button
                type="button"
                className="relay-button relay-button-small"
                onClick={() => choose(snoozeTimes(new Date())[choice])}
              >
                {choice === "hour" ? t("inbox.snoozeHour") : choice === "tomorrow" ? t("inbox.snoozeTomorrow") : t("inbox.snoozeWeek")}
              </button>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}

function ApprovalLink({ item, waitpoint }: { readonly item: InboxItem; readonly waitpoint: WaitpointView | null }): ReactNode {
  const { t, links } = useRelay();
  const origin = links.accessApprovalOrigin;
  const actions = Array.isArray(item.actions) ? (item.actions as { label?: unknown; url?: unknown }[]) : [];
  const candidates = [
    ...actions.map((action) => safeUrl(action.url)),
    waitpoint?.approval_url ?? null,
    links.accessApprovalUrl?.(item) ?? null,
  ].filter((url): url is string => url !== null && safeUrl(url) !== null);
  const href = candidates.find((url) => (origin === undefined ? true : onOrigin(url, origin))) ?? null;
  return (
    <div className="relay-stack">
      <p className="relay-muted">{t("inbox.approvalNote")}</p>
      {href === null ? null : (
        <a className="relay-button relay-button-small relay-button-primary" href={href} data-testid="relay-approval-link">
          {t("inbox.approvalOpen")}
        </a>
      )}
    </div>
  );
}

/**
 * One inbox item (X-16): read state as text and glyph, severity, the agent sender mark (C-24), the awaiting-response state (AG-35), its actions (on an approval item only a link to the Access approval surface, IN-6) and its controls: read or unread, archive, delete (which hides), snooze and the shortcut to the category's preferences.
 */
export function InboxItemView(props: InboxItemViewProps): ReactNode {
  const { item, categoryLabel, headingLevel, onOpen, onToggleRead, onArchive, onHide, onSnooze, onActionClick } = props;
  const { t, formatTime } = useRelay();
  const shortcut = usePreferenceShortcut();
  const titleId = useId();
  const title = text(item.title) ?? t("inbox.untitled");
  const body = text(item.body);
  const url = safeUrl(item.url);
  const severity = text(item.severity);
  const category = text(item.category);
  const created = text(item.last_activity_at) ?? text(item.created_at);
  const activity = typeof item.activity_count === "number" && item.activity_count > 1 ? item.activity_count : null;
  const agent = senderTypeOf(item) === "agent";
  const waitpoint = waitpointOf(item);
  const approval = isApprovalItem(item);
  const actions = Array.isArray(item.actions) ? (item.actions as { label?: unknown; url?: unknown }[]) : [];
  const Heading = headingLevel === 3 ? "h3" : "h4";
  const shortcutHref = category === null ? null : shortcut.href(category);
  const shortcutLabel = category === null ? t("inbox.settingsGeneric") : t("inbox.settings", { category: categoryLabel(category) });
  return (
    <li className={item.read ? "relay-item" : "relay-item relay-item-unread"} data-testid="relay-inbox-item" data-item-id={item.id}>
      <article aria-labelledby={titleId}>
        <div className="relay-item-meta">
          <span className="relay-status" data-testid="relay-read-state">
            <StatusGlyph glyph={item.read ? glyphs.read : glyphs.unread} />
            {item.read ? t("inbox.read") : t("inbox.unread")}
          </span>
          {severity === null ? null : (
            <span className="relay-tag">
              <StatusGlyph glyph={glyphs.severity} />
              {t("inbox.severity", { severity })}
            </span>
          )}
          {agent ? (
            <span className="relay-tag" data-testid="relay-agent-mark">
              <StatusGlyph glyph={glyphs.agent} />
              {t("inbox.senderAgent")}
            </span>
          ) : null}
          {category === null ? null : <span className="relay-tag">{categoryLabel(category)}</span>}
          {created === null ? null : (
            <time className="relay-muted" dateTime={created}>
              {formatTime(created)}
            </time>
          )}
          {activity === null ? null : <span className="relay-muted">{t("inbox.activity", { count: activity })}</span>}
        </div>
        <Heading className="relay-item-title" id={titleId}>
          {url === null ? (
            title
          ) : (
            <a className="relay-link" href={url} onClick={() => onOpen(item)}>
              {title}
            </a>
          )}
        </Heading>
        {body === null ? null : <p className="relay-item-body">{body}</p>}
        {waitpoint === null || waitpoint.kind === "approval" ? null : <WaitpointPanel waitpoint={waitpoint} />}
        {approval ? (
          <ApprovalLink item={item} waitpoint={waitpoint} />
        ) : actions.length === 0 ? null : (
          <div className="relay-item-actions">
            {actions.flatMap((action, index) => {
              const href = safeUrl(action.url);
              const label = text(action.label);
              if (href === null || label === null) return [];
              return [
                <a key={index} className="relay-button relay-button-small" href={href} onClick={() => onActionClick(item)}>
                  {label}
                </a>,
              ];
            })}
          </div>
        )}
        <div className="relay-item-actions" role="group" aria-label={t("inbox.itemActions", { title })}>
          <button type="button" className="relay-button relay-button-small" onClick={() => onToggleRead(item)}>
            {item.read ? t("inbox.markUnread") : t("inbox.markRead")}
          </button>
          <button type="button" className="relay-button relay-button-small" onClick={() => onArchive(item)}>
            {t("inbox.archive")}
          </button>
          <button type="button" className="relay-button relay-button-small" onClick={() => onHide(item)} data-testid="relay-delete">
            {t("inbox.delete")}
          </button>
          <SnoozeMenu item={item} onSnooze={onSnooze} />
          {shortcut.open !== null ? (
            <button
              type="button"
              className="relay-button relay-button-small"
              onClick={() => shortcut.open?.(category)}
              data-testid="relay-category-shortcut"
            >
              {shortcutLabel}
            </button>
          ) : shortcutHref === null ? null : (
            <a className="relay-button relay-button-small" href={shortcutHref} data-testid="relay-category-shortcut">
              {shortcutLabel}
            </a>
          )}
        </div>
      </article>
    </li>
  );
}
