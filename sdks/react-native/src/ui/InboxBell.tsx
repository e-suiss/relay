import { Pressable, Text, View } from 'react-native';
import { useInbox, useRelay } from './context';

/** The badge text of a count: nothing at zero, `99+` above 99. */
export function badgeText(count: number): string | null {
  if (count <= 0) return null;
  return count > 99 ? '99+' : String(count);
}

export interface InboxBellProps {
  readonly onPress: () => void;
  readonly testID?: string;
}

// X-32
// IN-20
/** The bell with the unseen badge. The badge is absolute counters from Relay, never a local increment. */
export function InboxBell({ onPress, testID }: InboxBellProps) {
  const { theme, t } = useRelay();
  const { counters } = useInbox();
  const unseen = counters?.unseen ?? 0;
  const badge = badgeText(unseen);
  const size = theme.minTouchTarget;
  return (
    <Pressable
      testID={testID ?? 'relay-inbox-bell'}
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={unseen > 0 ? t('inbox.bell', { count: unseen }) : t('inbox.bell.none')}
      hitSlop={8}
      style={{ minWidth: size, minHeight: size, alignItems: 'center', justifyContent: 'center' }}
    >
      <Text
        importantForAccessibility="no"
        accessibilityElementsHidden
        style={{ fontSize: theme.fontSize + 6, color: theme.colors.text }}
      >
        {'\u{1F514}'}
      </Text>
      {badge !== null ? (
        <View
          importantForAccessibility="no-hide-descendants"
          accessibilityElementsHidden
          style={{
            position: 'absolute',
            top: 2,
            right: 2,
            minWidth: 20,
            paddingHorizontal: 4,
            borderRadius: 10,
            backgroundColor: theme.colors.badge,
            alignItems: 'center',
          }}
        >
          <Text style={{ color: theme.colors.onBadge, fontSize: 12, fontWeight: '700' }}>{badge}</Text>
        </View>
      ) : null}
    </Pressable>
  );
}
