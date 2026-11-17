// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import type { ReactElement } from 'react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { RelayClient } from '../src/client';
import { memoryStore } from '../src/ports';
import type { InboxItem } from '../src/types';
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
    const parent = JSON.parse(element.parentElement?.getAttribute('data-style') ?? '{}') as { minHeight?: number };
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
    relay.inbox.reset([inboxItem() as InboxItem], counters(1, 1), 'c1');
    const { container } = renderWith(relay, <InboxList />);
    expect(screen.getByRole('button', { name: 'Siparişiniz yolda, Unread' })).toBeTruthy();
    expect(screen.getByText('Unread')).toBeTruthy();
    for (const height of minHeights(container)) expect(height).toBeGreaterThanOrEqual(44);
  });

  it('IN-15 archive waits in the undo buffer and undo sends nothing', async () => {
    vi.useFakeTimers();
    const { relay, requests } = client(() => json(200, {}));
    relay.inbox.reset([inboxItem() as InboxItem], counters(1, 1), 'c1');
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
    relay.inbox.reset([inboxItem({ read: true, state_version: 2 }) as InboxItem], counters(1, 0), 'c1');
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
    { category: 'account_security', channel: 'push', value: 'unset', effective: true, source: 'locked' },
    { category: 'order_updates', channel: 'push', value: 'unset', effective: true, source: 'class_default' },
    { category: 'order_updates', channel: 'email', value: 'unset', effective: true, source: 'class_default' },
  ],
  channels: [],
  workflows: [],
  scope_keys: [],
  profile: { quiet_hours: [], schedule: [], dnd_until: null, quiet_hours_email: false, digest: {} },
};

describe('X-32 X-51 PC-17 preference center', () => {
  it('X-51 a locked category is shown on with its reason and cannot be switched', async () => {
    const { relay } = client(() => json(200, preferences));
    renderWith(relay, <PreferenceCenter categories={[{ key: 'account_security', class: 'security', name: 'Security' }]} />);
    await screen.findByText('Notification preferences');
    expect(screen.getByLabelText('Security, Push: On (locked)')).toBeTruthy();
    expect(screen.queryByTestId('relay-pref-switch-account_security-push')).toBeNull();
    expect(screen.getByText('These notifications are required for your account and cannot be turned off.')).toBeTruthy();
  });

  it('X-51 push is shown off in device settings while the OS permission is denied', async () => {
    const { relay } = client(() => json(200, preferences));
    renderWith(relay, <PreferenceCenter permission="denied" />);
    expect(await screen.findByLabelText('order_updates, Push: Off in device settings')).toBeTruthy();
  });

  it('PC-17 turning a switch off offers three choices with none preselected, and Never writes an opt-out', async () => {
    const { relay, requests } = client(() => json(200, preferences));
    renderWith(relay, <PreferenceCenter />);
    const toggle = await screen.findByTestId('relay-pref-switch-order_updates-email');
    fireEvent.click(toggle);
    const dialog = await screen.findByRole('dialog');
    const choices = Array.from(dialog.querySelectorAll('button'));
    expect(choices.map((choice) => choice.textContent)).toEqual(['Get them instantly', 'Get a digest', 'Never']);
    for (const choice of choices) expect(choice.getAttribute('aria-selected')).toBeNull();
    const styles = new Set(choices.map((choice) => choice.getAttribute('data-style')?.replace(/"opacity":[0-9.]+/, '')));
    expect(styles.size).toBe(1);
    fireEvent.click(screen.getByText('Never'));
    await waitFor(() => {
      expect(requests.some((request) => request.method === 'PATCH')).toBe(true);
    });
    const patch = requests.find((request) => request.method === 'PATCH');
    expect(patch?.body).toEqual({
      preferences: [{ level: 'category_channel', category: 'order_updates', channel: 'email', value: 'opt_out' }],
    });
  });

  it('X-20 turning a switch on is a single tap', async () => {
    const off = {
      ...preferences,
      cells: [{ category: 'order_updates', channel: 'email', value: 'opt_out', effective: false, source: 'user' }],
    };
    const { relay, requests } = client(() => json(200, off));
    renderWith(relay, <PreferenceCenter />);
    fireEvent.click(await screen.findByTestId('relay-pref-switch-order_updates-email'));
    await waitFor(() => {
      expect(requests.find((request) => request.method === 'PATCH')?.body).toEqual({
        preferences: [{ level: 'category_channel', category: 'order_updates', channel: 'email', value: 'opt_in' }],
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
    expect(await screen.findByText('At least one channel must stay on for this category.')).toBeTruthy();
  });

  it('X-32 every control meets the touch target', async () => {
    const { relay } = client(() => json(200, preferences));
    const { container } = renderWith(relay, <PreferenceCenter />);
    await screen.findByTestId('relay-pref-switch-order_updates-email');
    for (const height of minHeights(container)) expect(height).toBeGreaterThanOrEqual(44);
  });
});
