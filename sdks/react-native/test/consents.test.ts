import { describe, expect, it } from 'vitest';
import { ConsentsClient } from '../src/consents';
import { approvalLink, isAgentItem, isApprovalItem, responderLabel } from '../src/inbox/view';
import type { InboxItem } from '../src/types';
import { WaitpointsClient } from '../src/waitpoints';
import { inboxItem, json, testHttp } from './helpers';

const consent = (overrides: Record<string, unknown> = {}) => ({
  object: 'consent',
  id: 'cns_01j9zq3k4m5n6p7q8r9s0t1v2w',
  brand: null,
  channel: 'email',
  status: 'active',
  consent_kind: 'explicit_opt_in',
  recipient_type: 'individual',
  source: 'checkout',
  occurred_at: '2026-11-01T10:00:00Z',
  ...overrides,
});

const page = (data: unknown[], nextCursor: string | null) => ({
  object: 'list',
  data,
  has_more: nextCursor !== null,
  next_cursor: nextCursor,
});

describe('X-44 consents read-only', () => {
  it('X-44 reads one page with the preferences token and sends no idempotency key', async () => {
    const { http, requests } = testHttp(() => json(200, page([consent()], null)));
    const list = await new ConsentsClient(http).list({ limit: 20 });
    expect(list.data).toHaveLength(1);
    expect(requests[0]?.method).toBe('GET');
    expect(requests[0]?.url).toBe('https://relay.example.com/v1/subscriber/consents?limit=20');
    expect(requests[0]?.headers['Idempotency-Key']).toBeUndefined();
  });

  it('X-44 follows the cursor until the last page', async () => {
    const { http, requests } = testHttp((request) =>
      request.url.includes('starting_after=c1')
        ? json(200, page([consent({ id: 'cns_01j9zq3k4m5n6p7q8r9s0t1v2x', channel: 'sms' })], null))
        : json(200, page([consent()], 'c1')),
    );
    const all = await new ConsentsClient(http).all();
    expect(all.map((item) => item.channel)).toEqual(['email', 'sms']);
    expect(requests).toHaveLength(2);
  });
});

describe('AG-35 waitpoint response', () => {
  it('AG-26 sends the option value as the response with the subject digest', async () => {
    const digest = `sha256:${'a'.repeat(64)}`;
    const { http, requests } = testHttp(() =>
      json(200, {
        object: 'waitpoint_response_receipt',
        waitpoint_id: 'wp_01j9zq3k4m5n6p7q8r9s0t1v2w',
        status: 'responded',
      }),
    );
    const receipt = await new WaitpointsClient(http).respond(
      'wp_01j9zq3k4m5n6p7q8r9s0t1v2w',
      'yes',
      digest,
    );
    expect(receipt.status).toBe('responded');
    expect(requests[0]?.method).toBe('POST');
    expect(requests[0]?.path).toBe(
      '/v1/subscriber/waitpoints/wp_01j9zq3k4m5n6p7q8r9s0t1v2w/response',
    );
    expect(requests[0]?.body).toEqual({ response: 'yes', subject_digest: digest });
    expect(requests[0]?.headers['Idempotency-Key']).toBeUndefined();
  });
});

const item = (overrides: Record<string, unknown> = {}) => inboxItem(overrides) as InboxItem;

describe('C-24 AG-32 AG-35 inbox item views', () => {
  it('C-24 an agent sender is told apart from human, system and an announcement', () => {
    expect(isAgentItem(item({ sender_type: 'agent' }))).toBe(true);
    expect(isAgentItem(item({ sender_type: 'human' }))).toBe(false);
    expect(isAgentItem(item({ sender_type: null }))).toBe(false);
    expect(isAgentItem(item())).toBe(false);
  });

  it('IN-6 AG-32 an approval is told by the flag or the waitpoint kind and links only over https', () => {
    const waitpoint = {
      id: 'wp_01j9zq3k4m5n6p7q8r9s0t1v2w',
      kind: 'approval',
      status: 'awaiting',
      subject_digest: null,
      options: [],
      responder: null,
      responded_at: null,
      approval_url: 'https://access.example.com/approvals/1',
    };
    expect(isApprovalItem(item({ approval: true }))).toBe(true);
    expect(isApprovalItem(item({ waitpoint }))).toBe(true);
    expect(isApprovalItem(item({ approval: false }))).toBe(false);
    expect(approvalLink(item({ waitpoint }))).toBe('https://access.example.com/approvals/1');
    expect(
      approvalLink(item({ waitpoint: { ...waitpoint, approval_url: 'javascript:alert(1)' } })),
    ).toBeNull();
    expect(approvalLink(item({ approval: true }))).toBeNull();
  });

  it('AG-35 names who responded', () => {
    expect(responderLabel({ kind: 'agent', recipient_id: 'r1' })).toBe('agent');
    expect(responderLabel({ kind: 'subscriber', recipient_id: 'r1' })).toBe('you');
    expect(responderLabel({ kind: 'subscriber', recipient_id: 'r1' }, 'r1')).toBe('you');
    expect(responderLabel({ kind: 'subscriber', recipient_id: 'r2' }, 'r1')).toBe('someone');
    expect(responderLabel(null)).toBe('someone');
  });
});
