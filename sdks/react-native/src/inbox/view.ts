import type { InboxItem, InboxWaitpointResponder } from '../types';

// C-24
// AG-34
/** Whether an AI agent produced the item; the item then carries the agent label on every surface. */
export function isAgentItem(item: InboxItem): boolean {
  return item.sender_type === 'agent';
}

// IN-6
// AG-32
/** Whether the item is an approval: its only action is the deep link to the Access approval surface and it is never answered here. */
export function isApprovalItem(item: InboxItem): boolean {
  return item.approval === true || item.waitpoint?.kind === 'approval';
}

/** The deep link of an approval item to the Access approval surface when it is an https address, else `null`. */
export function approvalLink(item: InboxItem): string | null {
  const url = item.waitpoint?.approval_url ?? null;
  return url !== null && /^https:\/\/\S+$/i.test(url) ? url : null;
}

export type ResponderLabel = 'you' | 'agent' | 'someone';

// AG-35
/** Who answered a waitpoint, as the item tells it: an agent, the signed-in subscriber, or another recipient when `subscriberRecipientId` is known and differs. */
export function responderLabel(
  responder: Pick<InboxWaitpointResponder, 'kind' | 'recipient_id'> | null | undefined,
  subscriberRecipientId?: string,
): ResponderLabel {
  if (!responder) return 'someone';
  if (responder.kind === 'agent') return 'agent';
  if (subscriberRecipientId !== undefined && responder.recipient_id !== subscriberRecipientId) {
    return 'someone';
  }
  return 'you';
}
