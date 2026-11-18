import type { ReactNode } from "react";
import { RelayRoot, useInboxState, useRelay } from "../context.js";
import { BellIcon } from "../icons.js";
import { pendingReadItems } from "./mark-all-read.js";
import { badgeCount, badgeText, type BadgeSource } from "./view.js";

/** The badge number with the optimistic update of a pending "mark all as read" (IN-19, X-17). */
export function useBadgeCount(source: BadgeSource = "unseen"): number {
  const { snapshot, pendingMarkAllRead } = useInboxState();
  if (snapshot === null) return 0;
  return badgeCount(snapshot.counters, source, pendingReadItems(snapshot.items, pendingMarkAllRead));
}

/** Props of {@link Bell}. */
export interface BellProps {
  /** What the badge counts; the tenant chooses per app (IN-18). */
  readonly badgeSource?: BadgeSource;
  readonly onClick?: () => void;
  /** Whether the inbox the bell opens is shown. */
  readonly expanded?: boolean;
  /** The id of the inbox the bell opens. */
  readonly controls?: string;
  /** Renders only the button, for use inside another component's themed root. */
  readonly bare?: boolean;
}

/** The bell with its badge (X-16): an absolute, server-computed count shown up to `99+` (IN-20). */
export function Bell({ bare = false, ...props }: BellProps): ReactNode {
  if (bare) return <BellButton {...props} />;
  return (
    <RelayRoot className="relay-inline">
      <BellButton {...props} />
    </RelayRoot>
  );
}

function BellButton({
  badgeSource = "unseen",
  onClick,
  expanded,
  controls,
}: Omit<BellProps, "bare">): ReactNode {
  const { t } = useRelay();
  const count = useBadgeCount(badgeSource);
  const text = badgeText(count);
  return (
    <button
      type="button"
      className="relay-bell"
      onClick={onClick}
      {...(expanded === undefined ? {} : { "aria-expanded": expanded })}
      {...(controls === undefined ? {} : { "aria-controls": controls })}
    >
      <BellIcon />
      <span className="relay-sr-only">{count > 0 ? t("bell.label", { count: text }) : t("bell.labelNone")}</span>
      {text === "" ? null : (
        <span className="relay-badge" aria-hidden="true" data-testid="relay-badge">
          {text}
        </span>
      )}
    </button>
  );
}
