import type { ReactNode } from "react";

/** A decorative bell icon; the control that holds it carries the text. */
export function BellIcon(): ReactNode {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <path
        fill="currentColor"
        d="M12 22a2.5 2.5 0 0 0 2.45-2h-4.9A2.5 2.5 0 0 0 12 22Zm7-6V11a7 7 0 0 0-5.5-6.84V3a1.5 1.5 0 0 0-3 0v1.16A7 7 0 0 0 5 11v5l-2 2v1h18v-1l-2-2Z"
      />
    </svg>
  );
}

/** A decorative status glyph shown next to a status text, so a status never depends on colour alone. */
export function StatusGlyph({ glyph }: { readonly glyph: string }): ReactNode {
  return (
    <span className="relay-status-icon" aria-hidden="true">
      {glyph}
    </span>
  );
}

/** Glyphs of the statuses the components show. */
export const glyphs = {
  unread: "●",
  read: "○",
  severity: "▲",
  agent: "⚙",
  awaiting: "⏳",
  done: "✓",
  stopped: "■",
  locked: "\u{1F512}︎",
  off: "✕",
  warning: "⚠︎",
  pending: "…",
} as const;
