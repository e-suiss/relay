// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import type { ReactElement } from 'react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { RelayClient } from '../src/client';
import { memoryStore } from '../src/ports';
import { RelayProvider } from '../src/ui/context';
import { InboxBell } from '../src/ui/InboxBell';
import { InboxList } from '../src/ui/InboxList';
import { PreferenceCenter } from '../src/ui/PreferenceCenter';
import {
  counters,
  fakeRandom,
  inboxItem,
  instantClock,
  ITEM_ID,
  json,
  mockFetch,
  problem,
  type Responder,
} from './helpers';
import { Linking } from './shims/react-native';

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

function client(responder: Responder) {
  const { fetch, requests } = mockFetch(responder);
  const relay = new RelayClient({
    baseUrl: 'https://relay.example.com',
    tokenProvider: () => Promise.resolve({ token: 'subscriber-token' }),
    storage: memoryStore(),
    realtime: false,
    fetch,
    clock: instantClock(),
    random: fakeRandom(),
    locale: 'en-US',
  });
  return { relay, requests };
}

function renderWith(relay: RelayClient, element: ReactElement, locale = 'en') {
  return render(
    <RelayProvider client={relay} manageLifecycle={false} locale={locale}>
      {element}
    </RelayProvider>,
  );
}

function minHeights(container: HTMLElement): number[] {
  return Array.from(container.querySelectorAll('button, [role="switch"]')).map((element) => {
    const style = JSON.parse(element.getAttribute('data-style') ?? '{}') as { minHeight?: number };
    const parent = JSON.parse(element.parentElement?.getAttribute('data-style') ?? '{}') as {
      minHeight?: number;
    };
    return Math.max(style.minHeight ?? 0, parent.minHeight ?? 0);
  });
}

describe('X-32 inbox components', () => {
  it('X-32 the bell announces the unseen count and caps the badge at 99+', () => {
    const { relay } = client(() => json(200, {}));
    relay.inbox.reset([], counters(1, 120, 120), 'c1');
    renderWith(relay, <InboxBell onPress={() => undefined} />);
    expect(screen.getByRole('button', { name: 'Notifications, 120 unseen' })).toBeTruthy();
    expect(screen.getByText('99+')).toBeTruthy();
  });

  it('X-32 the bell speaks Turkish', () => {
    const { relay } = client(() => json(200, {}));
    relay.inbox.reset([], counters(1, 0, 0), 'c1');
    renderWith(relay, <InboxBell onPress={() => undefined} />, 'tr-TR');
    expect(screen.getByRole('button', { name: 'Bildirimler, görülmemiş yok' })).toBeTruthy();
  });

  it('X-6 X-32 unread is told by text, not only by colour, and rows meet the touch target', () => {
    const { relay } = client(() => json(200, {}));
    relay.inbox.reset([inboxItem()], counters(1, 1), 'c1');
    const { container } = renderWith(relay, <InboxList />);
    expect(screen.getByRole('button', { name: 'Siparişiniz yolda, Unread' })).toBeTruthy();
    expect(screen.getByText('Unread')).toBeTruthy();
    for (const height of minHeights(container)) expect(height).toBeGreaterThanOrEqual(44);
  });

  it('IN-15 archive waits in the undo buffer and undo sends nothing', async () => {
    vi.useFakeTimers();
    const { relay, requests } = client(() => json(200, {}));
    relay.inbox.reset([inboxItem()], counters(1, 1), 'c1');
    renderWith(relay, <InboxList undoWindowMs={5000} />);
    fireEvent.click(screen.getByTestId(`relay-inbox-archive-${ITEM_ID}`));
    expect(screen.queryByTestId(`relay-inbox-item-${ITEM_ID}`)).toBeNull();
    fireEvent.click(screen.getByTestId('relay-inbox-undo'));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(6000);
    });
    expect(requests).toHaveLength(0);
    expect(screen.getByTestId(`relay-inbox-item-${ITEM_ID}`)).toBeTruthy();
  });

  it('IN-12 a reverse intent conflict made on screen shows the updated elsewhere notice', async () => {
    const { relay } = client((request) =>
      request.path.endsWith('/intents')
        ? problem(409, 'inbox_item_conflict', {
            current: { ...inboxItem({ state_version: 5, read: true }), object: undefined },
          })
        : json(200, {}),
    );
    relay.inbox.reset([inboxItem({ read: true, state_version: 2 })], counters(1, 0), 'c1');
    renderWith(relay, <InboxList />);
    fireEvent.click(screen.getByTestId(`relay-inbox-toggle-read-${ITEM_ID}`));
    await waitFor(() => {
      expect(screen.getByText('Updated on another device.')).toBeTruthy();
    });
  });
});

const preferences = {
  object: 'subscriber_preferences',
  subscriber_id: 'sub_01j9zq3k4m5n6p7q8r9s0t1v2w',
  cells: [
    {
      category: 'account_security',
      category_name: 'Account security',
      channel: 'push',
      value: 'unset',
      effective: true,
      source: 'locked',
      locked: true,
      lock_beneficiary: 'subscriber',
      digest_allowed: false,
      disabled_by_admin: false,
      disabled_in_device_settings: false,
    },
    {
      category: 'order_updates',
      category_name: 'Order updates',
      channel: 'push',
      value: 'unset',
      effective: true,
      source: 'class_default',
      locked: false,
      lock_beneficiary: null,
      digest_allowed: false,
      disabled_by_admin: false,
      disabled_in_device_settings: false,
    },
    {
      category: 'order_updates',
      category_name: 'Order updates',
      channel: 'email',
      value: 'unset',
      effective: true,
      source: 'class_default',
      locked: false,
      lock_beneficiary: null,
      digest_allowed: false,
      disabled_by_admin: false,
      disabled_in_device_settings: false,
    },
  ],
  channels: [],
  workflows: [],
  scope_keys: [],
  profile: { quiet_hours: [], schedule: [], dnd_until: null, quiet_hours_email: false, digest: {} },
};

describe('X-32 X-51 PC-17 preference center', () => {
  it('X-51 a locked category is shown on with its reason and cannot be switched', async () => {
    const { relay } = client(() => json(200, preferences));
    renderWith(
      relay,
      <PreferenceCenter
        categories={[{ key: 'account_security', class: 'security', name: 'Security' }]}
      />,
    );
    await screen.findByText('Notification preferences');
    expect(screen.getByLabelText('Security, Push: On (locked)')).toBeTruthy();
    expect(screen.queryByTestId('relay-pref-switch-account_security-push')).toBeNull();
    expect(
      screen.getByText(
        'These notifications are required for your account and cannot be turned off.',
      ),
    ).toBeTruthy();
  });

  it('X-51 push is shown off in device settings while the OS permission is denied', async () => {
    const { relay } = client(() => json(200, preferences));
    renderWith(relay, <PreferenceCenter permission="denied" />);
    expect(
      await screen.findByLabelText('Order updates, Push: Off in device settings'),
    ).toBeTruthy();
  });

  it('X-51 a tenant lock and a cell the administrator turned off are shown as labels', async () => {
    const tenant = {
      ...preferences,
      cells: [
        {
          ...preferences.cells[0],
          category: 'service_notices',
          category_name: 'Service notices',
          lock_beneficiary: 'tenant',
        },
        {
          ...preferences.cells[2],
          value: 'opt_out',
          effective: false,
          source: 'tenant',
          disabled_by_admin: true,
        },
      ],
    };
    const { relay } = client(() => json(200, tenant));
    renderWith(relay, <PreferenceCenter />);
    expect(await screen.findByLabelText('Service notices, Push: On (locked)')).toBeTruthy();
    expect(
      screen.getByText('These notifications are needed for the service and cannot be turned off.'),
    ).toBeTruthy();
    expect(
      screen.getByLabelText('Order updates, Email: Turned off by your administrator'),
    ).toBeTruthy();
    expect(screen.queryByTestId('relay-pref-switch-order_updates-email')).toBeNull();
  });

  it('PC-17 turning a switch off offers three choices with none preselected, and Never writes an opt-out', async () => {
    const { relay, requests } = client(() => json(200, preferences));
    renderWith(relay, <PreferenceCenter />);
    const toggle = await screen.findByTestId('relay-pref-switch-order_updates-email');
    fireEvent.click(toggle);
    const dialog = await screen.findByRole('dialog');
    const choices = Array.from(dialog.querySelectorAll('button'));
    expect(choices.map((choice) => choice.textContent)).toEqual([
      'Get them instantly',
      'Get a digest',
      'Never',
    ]);
    for (const choice of choices) expect(choice.getAttribute('aria-selected')).toBeNull();
    const styles = new Set(
      choices.map((choice) => choice.getAttribute('data-style')?.replace(/"opacity":[0-9.]+/, '')),
    );
    expect(styles.size).toBe(1);
    fireEvent.click(screen.getByText('Never'));
    await waitFor(() => {
      expect(requests.some((request) => request.method === 'PATCH')).toBe(true);
    });
    const patch = requests.find((request) => request.method === 'PATCH');
    expect(patch?.body).toEqual({
      preferences: [
        {
          level: 'category_channel',
          category: 'order_updates',
          channel: 'email',
          value: 'opt_out',
        },
      ],
    });
  });

  it('X-20 turning a switch on is a single tap', async () => {
    const off = {
      ...preferences,
      cells: [
        {
          category: 'order_updates',
          channel: 'email',
          value: 'opt_out',
          effective: false,
          source: 'user',
        },
      ],
    };
    const { relay, requests } = client(() => json(200, off));
    renderWith(relay, <PreferenceCenter />);
    fireEvent.click(await screen.findByTestId('relay-pref-switch-order_updates-email'));
    await waitFor(() => {
      expect(requests.find((request) => request.method === 'PATCH')?.body).toEqual({
        preferences: [
          {
            level: 'category_channel',
            category: 'order_updates',
            channel: 'email',
            value: 'opt_in',
          },
        ],
      });
    });
    expect(screen.queryByRole('dialog')).toBeNull();
  });

  it('PC-15 closing the last channel of a locked category tells the user why it failed', async () => {
    const { relay } = client((request) =>
      request.method === 'PATCH' ? problem(422, 'preference_last_channel') : json(200, preferences),
    );
    renderWith(relay, <PreferenceCenter />);
    fireEvent.click(await screen.findByTestId('relay-pref-switch-order_updates-push'));
    fireEvent.click(await screen.findByText('Never'));
    expect(
      await screen.findByText('At least one channel must stay on for this category.'),
    ).toBeTruthy();
  });

  it('X-32 every control meets the touch target', async () => {
    const { relay } = client(() => json(200, preferences));
    const { container } = renderWith(relay, <PreferenceCenter />);
    await screen.findByTestId('relay-pref-switch-order_updates-email');
    for (const height of minHeights(container)) expect(height).toBeGreaterThanOrEqual(44);
  });
});

const DIGEST = `sha256:${'b'.repeat(64)}`;
const WAITPOINT_ID = 'wp_01j9zq3k4m5n6p7q8r9s0t1v2w';

const waitpoint = (overrides: Record<string, unknown> = {}) => ({
  id: WAITPOINT_ID,
  kind: 'response',
  status: 'awaiting',
  subject_digest: DIGEST,
  options: [
    { label: 'Approve the plan', value: 'yes' },
    { label: 'Reject the plan', value: 'no' },
  ],
  responder: null,
  responded_at: null,
  approval_url: null,
  ...overrides,
});

describe('C-24 AG-35 agent items and waitpoints in the inbox', () => {
  it('C-24 AG-34 an agent item carries the agent label as text and in its accessible name', () => {
    const { relay } = client(() => json(200, {}));
    relay.inbox.reset([inboxItem({ sender_type: 'agent' })], counters(1, 1), 'c1');
    renderWith(relay, <InboxList />);
    expect(screen.getByText('Sent by an AI agent')).toBeTruthy();
    expect(
      screen.getByRole('button', { name: 'Siparişiniz yolda, Unread, sent by an AI agent' }),
    ).toBeTruthy();
  });

  it('C-24 a human or system item has no agent label', () => {
    const { relay } = client(() => json(200, {}));
    relay.inbox.reset([inboxItem({ sender_type: 'system' })], counters(1, 1), 'c1');
    renderWith(relay, <InboxList />);
    expect(screen.queryByTestId(`relay-inbox-agent-${ITEM_ID}`)).toBeNull();
  });

  it('AG-35 an awaiting waitpoint offers its options and a response shows who answered', async () => {
    const { relay, requests } = client((request) =>
      request.path.endsWith('/response')
        ? json(200, {
            object: 'waitpoint_response_receipt',
            waitpoint_id: WAITPOINT_ID,
            status: 'responded',
            responder: { kind: 'subscriber', recipient_id: 'rcp_1' },
            responded_at: '2026-11-18T09:00:00Z',
          })
        : json(200, {}),
    );
    relay.inbox.reset([inboxItem({ waitpoint: waitpoint() })], counters(1, 1), 'c1');
    const { container } = renderWith(relay, <InboxList />);
    expect(screen.getByText('Waiting for your response')).toBeTruthy();
    for (const height of minHeights(container)) expect(height).toBeGreaterThanOrEqual(44);
    fireEvent.click(screen.getByRole('button', { name: 'Respond: Approve the plan' }));
    expect(await screen.findByText(/^Answered by you on /)).toBeTruthy();
    const response = requests.find((request) => request.path.endsWith('/response'));
    expect(response?.method).toBe('POST');
    expect(response?.path).toBe(`/v1/subscriber/waitpoints/${WAITPOINT_ID}/response`);
    expect(response?.body).toEqual({ response: 'yes', subject_digest: DIGEST });
    expect(screen.queryByRole('button', { name: 'Respond: Reject the plan' })).toBeNull();
  });

  it('AG-35 a response that fails says so and offers the options again', async () => {
    const { relay } = client((request) =>
      request.path.endsWith('/response') ? problem(409, 'waitpoint_resolved') : json(200, {}),
    );
    relay.inbox.reset([inboxItem({ waitpoint: waitpoint() })], counters(1, 1), 'c1');
    renderWith(relay, <InboxList />);
    fireEvent.click(screen.getByRole('button', { name: 'Respond: Reject the plan' }));
    expect(await screen.findByText('The change could not be saved.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Respond: Reject the plan' })).toBeTruthy();
  });

  it('AG-35 processing, responded by an agent and no longer awaited are shown without options', () => {
    const { relay } = client(() => json(200, {}));
    relay.inbox.reset(
      [
        inboxItem({
          id: 'inb_01j9zq3k4m5n6p7q8r9s0t1v2a',
          waitpoint: waitpoint({ status: 'processing' }),
        }),
        inboxItem({
          id: 'inb_01j9zq3k4m5n6p7q8r9s0t1v2b',
          waitpoint: waitpoint({
            status: 'responded',
            responder: { kind: 'agent', recipient_id: 'rcp_2' },
            responded_at: '2026-11-18T08:30:00Z',
          }),
        }),
        inboxItem({
          id: 'inb_01j9zq3k4m5n6p7q8r9s0t1v2c',
          waitpoint: waitpoint({ status: 'not_awaited' }),
        }),
      ],
      counters(1, 3),
      'c1',
    );
    renderWith(relay, <InboxList />);
    expect(screen.getByText('Processing your response…')).toBeTruthy();
    expect(screen.getByText(/^Answered by an agent on /)).toBeTruthy();
    expect(screen.getByText('No longer expecting a response')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /^Respond:/ })).toBeNull();
  });

  it('AG-35 a response of another recipient is told apart when the subscriber is known', () => {
    const { relay } = client(() => json(200, {}));
    relay.inbox.reset(
      [
        inboxItem({
          waitpoint: waitpoint({
            status: 'responded',
            responder: { kind: 'subscriber', recipient_id: 'rcp_other' },
            responded_at: '2026-11-18T08:30:00Z',
          }),
        }),
      ],
      counters(1, 1),
      'c1',
    );
    renderWith(relay, <InboxList subscriberRecipientId="rcp_me" />, 'tr');
    expect(screen.getByText(/^Başka bir alıcı yanıtladı, /)).toBeTruthy();
  });

  it('IN-6 AG-32 an approval item shows only the link to the approval surface', () => {
    const opened: string[] = [];
    const { relay, requests } = client(() => json(200, {}));
    relay.inbox.reset(
      [
        inboxItem({
          approval: true,
          waitpoint: waitpoint({
            kind: 'approval',
            approval_url: 'https://access.example.com/approvals/42',
          }),
        }),
      ],
      counters(1, 1),
      'c1',
    );
    renderWith(relay, <InboxList onOpenUrl={(url) => opened.push(url)} />);
    expect(screen.getByText('Approvals are given in your account, not here.')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /^Respond:/ })).toBeNull();
    fireEvent.click(screen.getByRole('link', { name: 'Review in your account' }));
    expect(opened).toEqual(['https://access.example.com/approvals/42']);
    expect(requests).toHaveLength(0);
  });

  it('IN-6 the approval link opens with the system by default', () => {
    Linking.opened.length = 0;
    const { relay } = client(() => json(200, {}));
    relay.inbox.reset(
      [
        inboxItem({
          approval: true,
          waitpoint: waitpoint({
            kind: 'approval',
            options: [],
            approval_url: 'https://access.example.com/approvals/7',
          }),
        }),
      ],
      counters(1, 1),
      'c1',
    );
    renderWith(relay, <InboxList />);
    fireEvent.click(screen.getByRole('link', { name: 'Review in your account' }));
    expect(Linking.opened).toEqual(['https://access.example.com/approvals/7']);
  });
});

const BRAND = 'stn_01j9zq3k4m5n6p7q8r9s0t1v2w';

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

function withConsents(consents: unknown[] | 'fail'): Responder {
  return (request) => {
    if (request.path !== '/v1/subscriber/consents') return json(200, preferences);
    if (consents === 'fail') return problem(403, 'auth_insufficient_scope');
    return json(200, { object: 'list', data: consents, has_more: false, next_cursor: null });
  };
}

describe('X-44 PC-59 consents in the preference center', () => {
  it('X-44 shows the consents read-only with a link to Access and no switch', async () => {
    const opened: string[] = [];
    const sms = consent({
      id: 'cns_01j9zq3k4m5n6p7q8r9s0t1v2x',
      channel: 'sms',
      status: 'revoked',
      brand: BRAND,
    });
    const { relay, requests } = client(withConsents([consent(), sms]));
    renderWith(
      relay,
      <PreferenceCenter
        consentManageUrl="https://access.example.com/consents"
        brandName={(brand) => (brand === BRAND ? 'Shop' : null)}
        onOpenUrl={(url) => opened.push(url)}
      />,
    );
    expect(await screen.findByText('Marketing permissions')).toBeTruthy();
    expect(screen.getByLabelText('Email: Given')).toBeTruthy();
    expect(screen.getByLabelText('Shop, SMS: Withdrawn')).toBeTruthy();
    const section = screen.getByTestId('relay-consents');
    expect(section.querySelectorAll('[role="switch"], input')).toHaveLength(0);
    fireEvent.click(screen.getByRole('link', { name: 'Manage permissions in your account' }));
    expect(opened).toEqual(['https://access.example.com/consents']);
    const consentRequests = requests.filter((request) => request.path.includes('consent'));
    expect(consentRequests.map((request) => request.method)).toEqual(['GET']);
  });

  it('X-44 without a configured Access link no link is shown', async () => {
    const { relay } = client(withConsents([consent()]));
    renderWith(relay, <PreferenceCenter />);
    expect(await screen.findByLabelText('Email: Given')).toBeTruthy();
    expect(screen.queryByRole('link')).toBeNull();
  });

  it('X-44 no consents and no link hide the section', async () => {
    const { relay } = client(withConsents([]));
    renderWith(relay, <PreferenceCenter />);
    await screen.findByTestId('relay-pref-switch-order_updates-email');
    expect(screen.queryByTestId('relay-consents')).toBeNull();
  });

  it('X-44 consents that cannot be loaded are said to be unavailable next to the link', async () => {
    const { relay } = client(withConsents('fail'));
    renderWith(relay, <PreferenceCenter consentManageUrl="https://access.example.com/c" />);
    expect(await screen.findByText('Permission details are not shown here.')).toBeTruthy();
    expect(screen.getByRole('link', { name: 'Manage permissions in your account' })).toBeTruthy();
  });

  it('X-44 the consents speak Turkish and can be left out', async () => {
    const { relay, requests } = client(withConsents([consent({ status: 'pending_iys' })]));
    const { unmount } = renderWith(relay, <PreferenceCenter />, 'tr');
    expect(await screen.findByLabelText('E-posta: İYS bekleniyor')).toBeTruthy();
    expect(screen.getByText('Pazarlama izinleri')).toBeTruthy();
    unmount();
    requests.length = 0;
    renderWith(relay, <PreferenceCenter showConsents={false} />);
    await screen.findByTestId('relay-pref-switch-order_updates-email');
    expect(requests.some((request) => request.path === '/v1/subscriber/consents')).toBe(false);
    expect(screen.queryByTestId('relay-consents')).toBeNull();
  });
});
