import { useCallback, useEffect, useState } from 'react';
import { Modal, Pressable, ScrollView, Switch, Text, View } from 'react-native';
import { RelayError } from '../errors';
import type { MessageKey } from '../i18n';
import type { CategoryDefinition } from '../push/channels';
import type {
  Channel,
  DevicePermission,
  MyPreferencesPatch,
  PreferenceCell,
  SubscriberPreferences,
} from '../types';
import { useRelay, type RelayUi } from './context';

export type CellDisplay = 'on' | 'off' | 'locked' | 'admin_disabled' | 'os_disabled';

// X-51
// PC-15
// PC-16
/** How a cell is shown: locked cells cannot change, cells the administrator turned off are a label, and push cells are off in device settings when the server says so or this device's OS permission is denied. */
export function cellDisplay(
  cell: PreferenceCell,
  permission: DevicePermission | null,
): CellDisplay {
  if (cell.locked) return 'locked';
  if (cell.disabled_by_admin) return 'admin_disabled';
  if (cell.disabled_in_device_settings) return 'os_disabled';
  if ((cell.channel === 'push' || cell.channel === 'web_push') && permission === 'denied') {
    return 'os_disabled';
  }
  return cell.effective ? 'on' : 'off';
}

// PC-17
/** The choices of the step shown when a cell is turned off: none is preselected. */
export type StepChoice = 'instant' | 'digest' | 'never';

/** The preference write of a step choice, or `null` when nothing changes. */
export function stepPatch(
  cell: PreferenceCell,
  choice: StepChoice,
  preferences: SubscriberPreferences,
): MyPreferencesPatch | null {
  if (choice === 'instant') return null;
  if (choice === 'digest') {
    return { profile: { digest: { ...preferences.profile.digest, [cell.category]: 'digest' } } };
  }
  return {
    preferences: [
      {
        level: 'category_channel',
        category: cell.category,
        channel: cell.channel,
        value: 'opt_out',
      },
    ],
  };
}

/** The write that turns a cell on. */
export function enablePatch(cell: PreferenceCell): MyPreferencesPatch {
  return {
    preferences: [
      {
        level: 'category_channel',
        category: cell.category,
        channel: cell.channel,
        value: 'opt_in',
      },
    ],
  };
}

const ERROR_MESSAGES: Readonly<Record<string, MessageKey>> = {
  preference_last_channel: 'prefs.lastChannel',
  preference_digest_not_allowed: 'prefs.digestNotAllowed',
};

export interface PreferenceCenterProps {
  readonly categories?: readonly CategoryDefinition[];
  readonly channels?: readonly Channel[];
  readonly permission?: DevicePermission | null;
  readonly testID?: string;
}

function Choice(props: {
  readonly ui: RelayUi;
  readonly label: string;
  readonly onPress: () => void;
  readonly disabled?: boolean;
  readonly testID: string;
}) {
  const { theme } = props.ui;
  return (
    <Pressable
      testID={props.testID}
      onPress={props.onPress}
      disabled={props.disabled}
      accessibilityRole="button"
      accessibilityLabel={props.label}
      accessibilityState={{ disabled: props.disabled === true }}
      style={{
        minHeight: theme.minTouchTarget,
        justifyContent: 'center',
        paddingHorizontal: theme.spacing,
        marginTop: 8,
        borderRadius: theme.radius,
        borderWidth: 1,
        borderColor: theme.colors.border,
        backgroundColor: theme.colors.background,
        opacity: props.disabled === true ? 0.5 : 1,
      }}
    >
      <Text style={{ color: theme.colors.text, fontSize: theme.fontSize }}>{props.label}</Text>
    </Pressable>
  );
}

// X-32
// X-20
// X-51
// PC-17
// PC-18
/** The preference center: category by channel switches, locked categories with their reason, push cells off in device settings, and the three-option step when a switch is turned off. It writes preferences only; consents and the profile of the subscriber are never written. */
export function PreferenceCenter({
  categories,
  channels,
  permission = null,
  testID,
}: PreferenceCenterProps) {
  const ui = useRelay();
  const { client, theme, t } = ui;
  const [preferences, setPreferences] = useState<SubscriberPreferences | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [step, setStep] = useState<PreferenceCell | null>(null);

  useEffect(() => {
    let live = true;
    client.preferences
      .get()
      .then((loaded) => {
        if (live) setPreferences(loaded);
      })
      .catch(() => {
        if (live) setError(t('prefs.saveFailed'));
      });
    return () => {
      live = false;
    };
  }, [client, t]);

  const write = useCallback(
    async (patch: MyPreferencesPatch | null) => {
      if (patch === null) return;
      try {
        setPreferences(await client.preferences.update(patch));
        setError(null);
      } catch (failure) {
        const key = failure instanceof RelayError ? ERROR_MESSAGES[failure.code ?? ''] : undefined;
        setError(t(key ?? 'prefs.saveFailed'));
      }
    },
    [client, t],
  );

  if (preferences === null) {
    return (
      <View testID={testID ?? 'relay-preferences'} style={{ padding: theme.spacing }}>
        <Text style={{ color: theme.colors.textMuted }}>{error ?? t('inbox.loading')}</Text>
      </View>
    );
  }

  const names = new Map((categories ?? []).map((category) => [category.key, category]));
  const shownChannels = new Set(channels ?? preferences.cells.map((cell) => cell.channel));
  const grouped = new Map<string, PreferenceCell[]>();
  for (const cell of preferences.cells) {
    if (!shownChannels.has(cell.channel)) continue;
    grouped.set(cell.category, [...(grouped.get(cell.category) ?? []), cell]);
  }
  const stepCategory = step ? (names.get(step.category)?.name ?? step.category_name) : '';
  const digestOffered = step !== null && step.digest_allowed;

  return (
    <ScrollView
      testID={testID ?? 'relay-preferences'}
      style={{ backgroundColor: theme.colors.background }}
    >
      <Text
        accessibilityRole="header"
        style={{
          color: theme.colors.text,
          fontSize: theme.fontSize + 4,
          fontWeight: '700',
          padding: theme.spacing,
        }}
      >
        {t('prefs.title')}
      </Text>
      {error !== null ? (
        <Text
          accessibilityRole="alert"
          accessibilityLiveRegion="polite"
          style={{ color: theme.colors.danger, paddingHorizontal: theme.spacing }}
        >
          {error}
        </Text>
      ) : null}
      {[...grouped.entries()].map(([category, cells]) => {
        const label = names.get(category)?.name ?? cells[0]?.category_name ?? category;
        const locked = cells.find((cell) => cell.locked);
        return (
          <View
            key={category}
            style={{
              padding: theme.spacing,
              borderBottomWidth: 1,
              borderBottomColor: theme.colors.border,
            }}
          >
            <Text
              accessibilityRole="header"
              style={{ color: theme.colors.text, fontSize: theme.fontSize, fontWeight: '600' }}
            >
              {label}
            </Text>
            {locked ? (
              <Text style={{ color: theme.colors.textMuted, fontSize: theme.fontSize - 2 }}>
                {t(
                  locked.lock_beneficiary === 'tenant'
                    ? 'prefs.lockedHintTenant'
                    : 'prefs.lockedHint',
                )}
              </Text>
            ) : null}
            {cells.map((cell) => {
              const display = cellDisplay(cell, permission);
              const channelName = t(`channel.${cell.channel}` as MessageKey);
              const stateText =
                display === 'locked'
                  ? t('prefs.locked')
                  : display === 'admin_disabled'
                    ? t('prefs.adminDisabled')
                    : display === 'os_disabled'
                      ? t('prefs.osDisabled')
                      : display === 'on'
                        ? t('prefs.on')
                        : t('prefs.off');
              const accessibilityLabel = t('prefs.cell', {
                category: label,
                channel: channelName,
                state: stateText,
              });
              return (
                <View
                  key={cell.channel}
                  testID={`relay-pref-${cell.category}-${cell.channel}`}
                  style={{
                    flexDirection: 'row',
                    alignItems: 'center',
                    justifyContent: 'space-between',
                    minHeight: theme.minTouchTarget,
                  }}
                >
                  <Text style={{ color: theme.colors.text, fontSize: theme.fontSize, flex: 1 }}>
                    {channelName}
                  </Text>
                  {display === 'locked' ||
                  display === 'admin_disabled' ||
                  display === 'os_disabled' ? (
                    <Text
                      accessibilityLabel={accessibilityLabel}
                      accessibilityState={{ disabled: true }}
                      style={{ color: theme.colors.textMuted, fontSize: theme.fontSize - 2 }}
                    >
                      {stateText}
                    </Text>
                  ) : (
                    <Switch
                      testID={`relay-pref-switch-${cell.category}-${cell.channel}`}
                      value={display === 'on'}
                      accessibilityLabel={accessibilityLabel}
                      accessibilityRole="switch"
                      accessibilityState={{ checked: display === 'on' }}
                      trackColor={{ true: theme.colors.primary, false: theme.colors.border }}
                      onValueChange={(next) => {
                        if (next) void write(enablePatch(cell));
                        else setStep(cell);
                      }}
                    />
                  )}
                </View>
              );
            })}
          </View>
        );
      })}
      <Modal
        visible={step !== null}
        transparent
        animationType="fade"
        onRequestClose={() => {
          setStep(null);
        }}
      >
        <View
          style={{
            flex: 1,
            justifyContent: 'center',
            padding: theme.spacing * 2,
            backgroundColor: 'rgba(0,0,0,0.4)',
          }}
        >
          <View
            accessibilityViewIsModal
            style={{
              backgroundColor: theme.colors.surface,
              borderRadius: theme.radius,
              padding: theme.spacing * 1.5,
            }}
          >
            <Text
              accessibilityRole="header"
              style={{ color: theme.colors.text, fontSize: theme.fontSize + 2, fontWeight: '600' }}
            >
              {t('prefs.stepTitle', { category: stepCategory })}
            </Text>
            {(['instant', 'digest', 'never'] as const).map((choice) => {
              const key: MessageKey =
                choice === 'instant'
                  ? 'prefs.stepInstant'
                  : choice === 'digest'
                    ? 'prefs.stepDigest'
                    : 'prefs.stepNever';
              return (
                <Choice
                  key={choice}
                  ui={ui}
                  testID={`relay-pref-step-${choice}`}
                  label={t(key)}
                  disabled={choice === 'digest' && !digestOffered}
                  onPress={() => {
                    const cell = step;
                    setStep(null);
                    if (cell) void write(stepPatch(cell, choice, preferences));
                  }}
                />
              );
            })}
          </View>
        </View>
      </Modal>
    </ScrollView>
  );
}
