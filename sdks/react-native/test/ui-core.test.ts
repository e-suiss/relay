import { describe, expect, it } from 'vitest';
import { MESSAGES, placeholders, resolveLocale, translate } from '../src/i18n';
import { badgeText } from '../src/ui/InboxBell';
import { cellDisplay, enablePatch, stepPatch } from '../src/ui/PreferenceCenter';
import { buildTheme, contrast, darkTheme, lightTheme, MIN_TOUCH_TARGET } from '../src/ui/theme';
import type { PreferenceCell, SubscriberPreferences } from '../src/types';
import { readJson } from './helpers';

describe('X-32 localisation', () => {
  it('X-32 Turkish and English carry the same keys and placeholders', () => {
    expect(Object.keys(MESSAGES.tr).sort()).toEqual(Object.keys(MESSAGES.en).sort());
    for (const key of Object.keys(MESSAGES.en) as (keyof typeof MESSAGES.en)[]) {
      expect(placeholders(MESSAGES.tr[key]), key).toEqual(placeholders(MESSAGES.en[key]));
    }
  });

  it('X-32 resolves BCP 47 tags and fills placeholders', () => {
    expect(resolveLocale('tr-TR')).toBe('tr');
    expect(resolveLocale('en-GB')).toBe('en');
    expect(resolveLocale('de')).toBe('en');
    expect(resolveLocale(undefined)).toBe('en');
    expect(translate('tr', 'inbox.bell', { count: 3 })).toBe('Bildirimler, 3 görülmemiş');
    expect(translate('en', 'inbox.bell', { count: 3 }, { 'inbox.bell': 'Bell {count}' })).toBe('Bell 3');
  });

  it('CH-33 the generic push text matches the server and the shared vector', () => {
    const vector = readJson<{ fallback: Record<'tr' | 'en', { title: string; body: string }> }>(
      'conformance/sdk/mobile/push_payloads.json',
    );
    for (const locale of ['tr', 'en'] as const) {
      expect(MESSAGES[locale]['push.fallback.title']).toBe(vector.fallback[locale].title);
      expect(MESSAGES[locale]['push.fallback.body']).toBe(vector.fallback[locale].body);
    }
  });
});

describe('X-32 theming and accessibility tokens', () => {
  const pairs = (colors: typeof lightTheme.colors): [string, string, string][] => [
    ['text/background', colors.text, colors.background],
    ['text/surface', colors.text, colors.surface],
    ['textMuted/background', colors.textMuted, colors.background],
    ['textMuted/surface', colors.textMuted, colors.surface],
    ['primary/background', colors.primary, colors.background],
    ['primary/surface', colors.primary, colors.surface],
    ['onPrimary/primary', colors.onPrimary, colors.primary],
    ['danger/background', colors.danger, colors.background],
    ['onBadge/badge', colors.onBadge, colors.badge],
  ];

  for (const theme of [lightTheme, darkTheme]) {
    it(`X-32 WCAG 2.2 AA contrast of the ${theme.scheme} theme is at least 4.5:1`, () => {
      for (const [name, foreground, background] of pairs(theme.colors)) {
        expect(contrast(foreground, background), name).toBeGreaterThanOrEqual(4.5);
      }
    });
  }

  it('X-32 a brand replaces the accent and the touch target never drops below 44', () => {
    const theme = buildTheme('light', { primary: '#004D40', radius: 4 }, { minTouchTarget: 30 });
    expect(theme.colors.primary).toBe('#004D40');
    expect(theme.radius).toBe(4);
    expect(theme.minTouchTarget).toBe(MIN_TOUCH_TARGET);
  });

  it('IN-20 the badge caps at 99+', () => {
    expect(badgeText(0)).toBeNull();
    expect(badgeText(7)).toBe('7');
    expect(badgeText(100)).toBe('99+');
  });
});

const cell = (overrides: Partial<PreferenceCell> = {}): PreferenceCell => ({
  category: 'order_updates',
  channel: 'push',
  value: 'unset',
  effective: true,
  source: 'class_default',
  ...overrides,
});

describe('X-51 PC-17 preference cells', () => {
  it('X-51 shows locked, off in device settings, on and off', () => {
    expect(cellDisplay(cell({ source: 'locked' }), 'denied')).toBe('locked');
    expect(cellDisplay(cell(), 'denied')).toBe('os_disabled');
    expect(cellDisplay(cell({ channel: 'email' }), 'denied')).toBe('on');
    expect(cellDisplay(cell({ effective: false }), 'granted')).toBe('off');
  });

  it('PC-17 the three choices write nothing, a digest or an opt-out', () => {
    const preferences = {
      object: 'subscriber_preferences',
      subscriber_id: 'sub_01j9zq3k4m5n6p7q8r9s0t1v2w',
      cells: [],
      channels: [],
      workflows: [],
      scope_keys: [],
      profile: { quiet_hours: [], schedule: [], dnd_until: null, quiet_hours_email: false, digest: { mentions: 'instant' } },
    } as unknown as SubscriberPreferences;
    expect(stepPatch(cell(), 'instant', preferences)).toBeNull();
    expect(stepPatch(cell(), 'digest', preferences)).toEqual({
      profile: { digest: { mentions: 'instant', order_updates: 'digest' } },
    });
    expect(stepPatch(cell(), 'never', preferences)).toEqual({
      preferences: [{ level: 'category_channel', category: 'order_updates', channel: 'push', value: 'opt_out' }],
    });
    expect(enablePatch(cell())).toEqual({
      preferences: [{ level: 'category_channel', category: 'order_updates', channel: 'push', value: 'opt_in' }],
    });
  });
});
