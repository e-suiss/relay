import type {
  InboxItem,
  InboxSenderType,
  InboxWaitpoint,
  RelaySubscriberClient,
} from "@esuiss/relay/browser";

/** Who produced a notification (C-24). */
export type SenderType = InboxSenderType;

/** The sender type an item carries, or null when it carries none, as on an announcement. */
export function senderTypeOf(item: InboxItem): SenderType | null {
  return item.sender_type ?? null;
}

/** Who answered a waitpoint. */
export interface WaitpointResponderView {
  readonly kind: "subscriber" | "agent";
  readonly recipient_id?: string;
  readonly external_id?: string;
}

/** The waitpoint of an awaiting-response item. */
export type WaitpointView = InboxWaitpoint;

/** One response choice of a waitpoint item. */
export type WaitpointOption = InboxWaitpoint["options"][number];

/** The waitpoint state an awaiting-response item shows (§8.6, AG-35). */
export type WaitpointStatus = InboxWaitpoint["status"];

/** The waitpoint an item carries, or null. */
export function waitpointOf(item: InboxItem): WaitpointView | null {
  return item.waitpoint ?? null;
}

/** Whether an item is an approval (IN-6): its actions may only link to the Access approval surface. */
export function isApprovalItem(item: InboxItem): boolean {
  return item.approval === true || item.waitpoint?.kind === "approval";
}

/** A read-only copy of one marketing consent as Access recorded it (X-44). */
export interface ConsentView {
  readonly channel: string;
  readonly status: "none" | "pending" | "pending_iys" | "active" | "revoked" | "expired";
  readonly brand?: string | null;
  readonly occurred_at?: string | null;
}

/**
 * Reads the subscriber's consents for the preference center. null means they could not be read: the center then shows no status, only the link to Access.
 */
export type ConsentSource = () => Promise<readonly ConsentView[] | null>;

/** A consent source that reads nothing, for a center that should show no consent status. */
export const noConsents: ConsentSource = () => Promise.resolve(null);

/** The default consent source (X-44, PC-59): every page of `listMyConsents`, read-only; null when it fails. */
export function apiConsents(client: RelaySubscriberClient | null): ConsentSource {
  return async () => {
    if (client === null) return null;
    try {
      const consents = await client.paginate("listMyConsents", { query: { limit: 100 } }).toArray();
      return consents as readonly ConsentView[];
    } catch {
      return null;
    }
  };
}
