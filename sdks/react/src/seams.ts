import type { InboxItem } from "@esuiss/relay/browser";

/** Who produced a notification (C-24). */
export type SenderType = "human" | "system" | "agent";

/** The sender type an item carries, or null while the inbox item has no such field. */
export function senderTypeOf(item: InboxItem): SenderType | null {
  const value = item.sender_type;
  return value === "human" || value === "system" || value === "agent" ? value : null;
}

/** Who answered a waitpoint. */
export interface WaitpointResponderView {
  readonly kind: "subscriber" | "agent";
  readonly recipient_id?: string;
  readonly external_id?: string;
}

/** One response choice of a waitpoint item. */
export interface WaitpointOption {
  readonly label: string;
  readonly value: unknown;
}

/** The waitpoint state an awaiting-response item shows (§8.6, AG-35). */
export type WaitpointStatus = "awaiting" | "processing" | "responded" | "not_awaited";

/** The waitpoint of an awaiting-response item. */
export interface WaitpointView {
  readonly id: string;
  readonly kind: "response" | "approval";
  readonly status: WaitpointStatus;
  readonly subject_digest: string | null;
  readonly options: readonly WaitpointOption[];
  readonly responder: WaitpointResponderView | null;
  readonly responded_at: string | null;
  readonly approval_url: string | null;
}

const statuses: ReadonlySet<string> = new Set([
  "awaiting",
  "processing",
  "responded",
  "not_awaited",
]);

function text(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

/**
 * The waitpoint an item carries, or null. The inbox item has no waitpoint field yet, so this reads an optional `waitpoint` object and gives null when it is absent or malformed.
 */
export function waitpointOf(item: InboxItem): WaitpointView | null {
  const raw = item.waitpoint;
  if (typeof raw !== "object" || raw === null) return null;
  const record = raw as Record<string, unknown>;
  const id = text(record.id);
  if (id === null) return null;
  const status =
    typeof record.status === "string" && statuses.has(record.status) ? record.status : "awaiting";
  const options = Array.isArray(record.options)
    ? record.options.flatMap((option: unknown) => {
        if (typeof option !== "object" || option === null) return [];
        const label = text((option as Record<string, unknown>).label);
        return label === null ? [] : [{ label, value: (option as Record<string, unknown>).value }];
      })
    : [];
  const responder = record.responder;
  return {
    id,
    kind: record.kind === "approval" ? "approval" : "response",
    status: status as WaitpointStatus,
    subject_digest: text(record.subject_digest),
    options,
    responder:
      typeof responder === "object" && responder !== null
        ? (responder as WaitpointResponderView)
        : null,
    responded_at: text(record.responded_at),
    approval_url: text(record.approval_url),
  };
}

/** Whether an item is an approval (IN-6): its actions may only link to the Access approval surface. */
export function isApprovalItem(item: InboxItem): boolean {
  return item.approval === true || waitpointOf(item)?.kind === "approval";
}

/** A read-only copy of one marketing consent as Access recorded it (X-44). */
export interface ConsentView {
  readonly channel: string;
  readonly status: "none" | "pending" | "pending_iys" | "active" | "revoked" | "expired";
  readonly brand?: string | null;
  readonly occurred_at?: string | null;
}

/**
 * Reads the subscriber's consents for the preference center. The subscriber API has no consent operation yet, so the default gives null: the center then shows a link to Access instead of a status.
 */
export type ConsentSource = () => Promise<readonly ConsentView[] | null>;

/** The default consent source while the subscriber API has no consent operation. */
export const noConsents: ConsentSource = () => Promise.resolve(null);
