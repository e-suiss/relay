import { Pressable, Text, View } from 'react-native';
import type { MessageKey } from '../i18n';
import type { Consent } from '../types';
import { useRelay } from './context';
import { openLink } from './links';

export interface ConsentSummaryProps {
  /** The consents to show; `null` when they could not be loaded. */
  readonly consents: readonly Consent[] | null;
  /** Where the subscriber changes consents in Access; no link is shown without it. */
  readonly manageUrl?: string | null;
  /** The display name of a brand (a subtenant id, `null` for the tenant itself), or `null` to show none. */
  readonly brandName?: (brand: string | null) => string | null;
  /** Opens the Access link; the system opens it by default. */
  readonly onOpenUrl?: (url: string) => void;
  readonly testID?: string;
}

// X-44
// PC-59
// X-31
/** A read-only view of the subscriber's commercial consents next to the preferences, with a link to Access to change them. It has no control that changes a consent. */
export function ConsentSummary({
  consents,
  manageUrl,
  brandName,
  onOpenUrl,
  testID,
}: ConsentSummaryProps) {
  const { theme, t } = useRelay();
  const link = manageUrl ?? null;
  return (
    <View
      testID={testID ?? 'relay-consents'}
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
        {t('prefs.consents')}
      </Text>
      <Text style={{ color: theme.colors.textMuted, fontSize: theme.fontSize - 2 }}>
        {t('prefs.consentsHint')}
      </Text>
      {consents === null ? (
        <Text style={{ color: theme.colors.textMuted, fontSize: theme.fontSize - 2 }}>
          {t('prefs.consentsUnavailable')}
        </Text>
      ) : consents.length === 0 ? (
        <Text style={{ color: theme.colors.textMuted, fontSize: theme.fontSize - 2 }}>
          {t('prefs.consentsEmpty')}
        </Text>
      ) : (
        consents.map((consent) => {
          const channel = t(`channel.${consent.channel}` as MessageKey);
          const status = t(`consent.${consent.status}` as MessageKey);
          const brand = brandName?.(consent.brand) ?? null;
          const label =
            brand === null
              ? t('prefs.consentStatus', { channel, status })
              : t('prefs.consentStatusBrand', { brand, channel, status });
          return (
            <View
              key={consent.id}
              testID={`relay-consent-${consent.id}`}
              accessible
              accessibilityLabel={label}
              style={{
                flexDirection: 'row',
                alignItems: 'center',
                justifyContent: 'space-between',
                minHeight: theme.minTouchTarget,
              }}
            >
              <Text style={{ color: theme.colors.text, fontSize: theme.fontSize, flex: 1 }}>
                {brand === null ? channel : `${brand}, ${channel}`}
              </Text>
              <Text style={{ color: theme.colors.textMuted, fontSize: theme.fontSize - 2 }}>
                {status}
              </Text>
            </View>
          );
        })
      )}
      {link !== null ? (
        <Pressable
          testID="relay-consents-manage"
          onPress={() => {
            openLink(link, onOpenUrl);
          }}
          accessibilityRole="link"
          accessibilityLabel={t('prefs.manageConsents')}
          style={{ minHeight: theme.minTouchTarget, justifyContent: 'center', marginTop: 8 }}
        >
          <Text
            style={{
              color: theme.colors.primary,
              fontSize: theme.fontSize,
              textDecorationLine: 'underline',
            }}
          >
            {t('prefs.manageConsents')}
          </Text>
        </Pressable>
      ) : null}
    </View>
  );
}
