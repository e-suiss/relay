import { createElement, Fragment, type ReactNode } from 'react';

type Props = Record<string, unknown> & { children?: ReactNode };

type Style = Record<string, unknown> | undefined | null | false | Style[];

function flatten(style: unknown): Record<string, unknown> {
  if (Array.isArray(style))
    return Object.assign({}, ...style.map(flatten)) as Record<string, unknown>;
  if (style && typeof style === 'object') return style as Record<string, unknown>;
  return {};
}

function common(props: Props): Record<string, unknown> {
  const state = (props.accessibilityState ?? {}) as Record<string, unknown>;
  const attributes: Record<string, unknown> = {
    'data-testid': props.testID,
    'aria-label': props.accessibilityLabel,
    'data-style': JSON.stringify(flatten(props.style as Style)),
  };
  if (props.accessibilityRole !== undefined) attributes.role = props.accessibilityRole;
  if (state.disabled !== undefined) attributes['aria-disabled'] = String(state.disabled);
  if (state.checked !== undefined) attributes['aria-checked'] = String(state.checked);
  if (state.selected !== undefined) attributes['aria-selected'] = String(state.selected);
  if (props.accessibilityLiveRegion !== undefined)
    attributes['aria-live'] = props.accessibilityLiveRegion;
  if (
    props.importantForAccessibility === 'no-hide-descendants' ||
    props.accessibilityElementsHidden === true
  ) {
    attributes['aria-hidden'] = 'true';
  }
  return attributes;
}

export function View(props: Props) {
  return createElement('div', common(props), props.children);
}

export function ScrollView(props: Props) {
  return createElement('div', common(props), props.children);
}

export function Text(props: Props) {
  return createElement('span', common(props), props.children);
}

export function Pressable(props: Props) {
  const onPress = props.onPress as (() => void) | undefined;
  const children = props.children as ReactNode | ((state: { pressed: boolean }) => ReactNode);
  return createElement(
    'button',
    {
      ...common(props),
      role: props.accessibilityRole ?? 'button',
      disabled: props.disabled === true,
      onClick: () => onPress?.(),
    },
    typeof children === 'function' ? children({ pressed: false }) : children,
  );
}

export function Switch(props: Props) {
  const onValueChange = props.onValueChange as ((value: boolean) => void) | undefined;
  return createElement('input', {
    ...common(props),
    type: 'checkbox',
    role: 'switch',
    checked: props.value === true,
    disabled: props.disabled === true,
    onChange: (event: { target: { checked: boolean } }) => onValueChange?.(event.target.checked),
  });
}

export function FlatList(props: Props) {
  const data = (props.data ?? []) as unknown[];
  const keyExtractor = props.keyExtractor as (item: unknown, index: number) => string;
  const renderItem = props.renderItem as (info: { item: unknown; index: number }) => ReactNode;
  return createElement(
    'div',
    common(props),
    data.length === 0
      ? (props.ListEmptyComponent as ReactNode)
      : data.map((item, index) =>
          createElement(Fragment, { key: keyExtractor(item, index) }, renderItem({ item, index })),
        ),
  );
}

export function Modal(props: Props) {
  return props.visible === true ? createElement('div', { role: 'dialog' }, props.children) : null;
}

export const StyleSheet = {
  create: <T,>(styles: T): T => styles,
  flatten,
};

type AppStateListener = (state: string) => void;
const appStateListeners = new Set<AppStateListener>();

export const AppState = {
  currentState: 'active',
  addEventListener: (_type: string, listener: AppStateListener) => {
    appStateListeners.add(listener);
    return { remove: () => appStateListeners.delete(listener) };
  },
  emit: (state: string) => {
    AppState.currentState = state;
    for (const listener of appStateListeners) listener(state);
  },
};

export const Platform = {
  OS: 'ios',
  select: <T,>(options: { ios?: T; android?: T; default?: T }): T | undefined =>
    options.ios ?? options.default,
};

export function useColorScheme(): 'light' | 'dark' {
  return 'light';
}
