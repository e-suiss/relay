import type { AndroidChannelImportance } from '../types';

export type MessageClass =
  | 'security'
  | 'action_required'
  | 'transactional'
  | 'operational'
  | 'social'
  | 'marketing'
  | 'system';

export type InterruptionLevel = 'passive' | 'active' | 'time-sensitive' | 'critical';

/** A notification category of the app, as the tenant defined it in Relay. */
export interface CategoryDefinition {
  readonly key: string;
  readonly class: MessageClass;
  readonly critical?: boolean;
  readonly name?: string;
}

/** One Android notification channel the SDK creates. Its id never changes between app versions. */
export interface AndroidChannelSpec {
  readonly id: string;
  readonly category: string;
  readonly level: InterruptionLevel;
  readonly importance: AndroidChannelImportance;
  readonly bypassDnd: boolean;
}

const CATEGORY_KEY = /^[a-z][a-z0-9_]{0,47}$/;
const LEVELS: readonly InterruptionLevel[] = ['passive', 'active', 'time-sensitive'];
const CLASSES: readonly MessageClass[] = [
  'security',
  'action_required',
  'transactional',
  'operational',
  'social',
  'marketing',
  'system',
];

const CEILING: Readonly<Record<MessageClass, number>> = {
  security: 2,
  action_required: 2,
  transactional: 2,
  operational: 1,
  social: 1,
  marketing: 0,
  system: -1,
};

const ACTIVE_IMPORTANCE: Readonly<Record<MessageClass, AndroidChannelImportance>> = {
  security: 'default',
  action_required: 'default',
  transactional: 'default',
  operational: 'default',
  social: 'low',
  marketing: 'low',
  system: 'none',
};

// CH-30
// CH-65 (3)
/** The stable channel id of a category at an interruption level: `relay.<category>.<level>`. */
export function androidChannelId(category: string, level: InterruptionLevel): string {
  if (!CATEGORY_KEY.test(category)) throw new Error(`category ${category} is not a channel name`);
  return `relay.${category}.${level}`;
}

function importance(level: InterruptionLevel, cls: MessageClass): AndroidChannelImportance {
  if (level === 'passive') return 'low';
  if (level === 'active') return ACTIVE_IMPORTANCE[cls];
  return 'high';
}

// CH-30
// CH-65
// CH-68
/** The Android channels of the app's categories: one per level up to the class ceiling, plus `critical` for a declared critical category. */
export function androidChannels(categories: readonly CategoryDefinition[]): AndroidChannelSpec[] {
  const channels: AndroidChannelSpec[] = [];
  for (const category of categories) {
    if (!CLASSES.includes(category.class)) {
      throw new Error(`category ${category.key} has an unknown class`);
    }
    const ceiling = CEILING[category.class];
    const levels: InterruptionLevel[] = LEVELS.slice(0, ceiling + 1);
    if (category.critical === true && ceiling >= 0) levels.push('critical');
    for (const level of levels) {
      channels.push({
        id: androidChannelId(category.key, level),
        category: category.key,
        level,
        importance: importance(level, category.class),
        bypassDnd: level === 'critical',
      });
    }
    if (ceiling < 0) androidChannelId(category.key, 'passive');
  }
  return channels;
}

// CH-29
/** Whether the first permission request may be provisional: only when every class the app starts with is marketing or social. */
export function provisionalAllowed(classes: readonly MessageClass[]): boolean {
  return classes.length > 0 && classes.every((cls) => cls === 'marketing' || cls === 'social');
}
