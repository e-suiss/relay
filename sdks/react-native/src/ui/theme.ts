export interface RelayColors {
  readonly background: string;
  readonly surface: string;
  readonly text: string;
  readonly textMuted: string;
  readonly primary: string;
  readonly onPrimary: string;
  readonly border: string;
  readonly danger: string;
  readonly badge: string;
  readonly onBadge: string;
}

export interface RelayTheme {
  readonly scheme: 'light' | 'dark';
  readonly colors: RelayColors;
  readonly radius: number;
  readonly spacing: number;
  readonly fontSize: number;
  readonly minTouchTarget: number;
}

/** A tenant or subtenant brand: it may replace the accent and the corner radius. */
export interface RelayBrand {
  readonly primary?: string;
  readonly onPrimary?: string;
  readonly radius?: number;
}

export const MIN_TOUCH_TARGET = 44;

export const lightTheme: RelayTheme = {
  scheme: 'light',
  colors: {
    background: '#FFFFFF',
    surface: '#F5F6F8',
    text: '#1A1C20',
    textMuted: '#4B5160',
    primary: '#1F5FD1',
    onPrimary: '#FFFFFF',
    border: '#D0D4DC',
    danger: '#B3261E',
    badge: '#B3261E',
    onBadge: '#FFFFFF',
  },
  radius: 12,
  spacing: 12,
  fontSize: 16,
  minTouchTarget: MIN_TOUCH_TARGET,
};

export const darkTheme: RelayTheme = {
  scheme: 'dark',
  colors: {
    background: '#121317',
    surface: '#1E2026',
    text: '#ECEDEF',
    textMuted: '#B4B8C2',
    primary: '#8AB4FF',
    onPrimary: '#0B1B3A',
    border: '#3A3F4B',
    danger: '#FFB4AB',
    badge: '#FFB4AB',
    onBadge: '#3B0907',
  },
  radius: 12,
  spacing: 12,
  fontSize: 16,
  minTouchTarget: MIN_TOUCH_TARGET,
};

/** The theme of a colour scheme with a brand and explicit overrides applied; the touch target never drops below 44. */
export function buildTheme(
  scheme: 'light' | 'dark',
  brand: RelayBrand = {},
  overrides: Partial<Omit<RelayTheme, 'colors'>> & { colors?: Partial<RelayColors> } = {},
): RelayTheme {
  const base = scheme === 'dark' ? darkTheme : lightTheme;
  return {
    ...base,
    ...overrides,
    radius: overrides.radius ?? brand.radius ?? base.radius,
    minTouchTarget: Math.max(MIN_TOUCH_TARGET, overrides.minTouchTarget ?? base.minTouchTarget),
    colors: {
      ...base.colors,
      ...(brand.primary ? { primary: brand.primary } : {}),
      ...(brand.onPrimary ? { onPrimary: brand.onPrimary } : {}),
      ...overrides.colors,
    },
  };
}

function channel(value: number): number {
  const c = value / 255;
  return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}

/** WCAG relative luminance of a `#RRGGBB` colour. */
export function luminance(hex: string): number {
  const match = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex);
  if (!match) throw new Error(`${hex} is not #RRGGBB`);
  const [r, g, b] = [match[1], match[2], match[3]].map((part) => channel(parseInt(part ?? '0', 16)));
  return 0.2126 * (r ?? 0) + 0.7152 * (g ?? 0) + 0.0722 * (b ?? 0);
}

/** WCAG contrast ratio of two `#RRGGBB` colours. */
export function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return ((hi ?? 0) + 0.05) / ((lo ?? 0) + 0.05);
}
