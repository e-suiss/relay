import { useState } from 'react';
import { Pressable, Text, View } from 'react-native';
import { formatDateTime, type MessageKey } from '../i18n';
import { approvalLink, isApprovalItem, responderLabel } from '../inbox/view';
import type { InboxItem, InboxWaitpointStatus, WaitpointResponseReceipt } from '../types';
import { useRelay, type RelayUi } from './context';
import { openLink } from './links';

export interface WaitpointPanelProps {
  readonly item: InboxItem;
  /** The recipient id of the signed-in subscriber, to tell its own response from another recipient's. */
  readonly subscriberRecipientId?: string;
  /** Opens the approval link; the system opens it by default. */
  readonly onOpenUrl?: (url: string) => void;
}

type Receipt = Pick<WaitpointResponseReceipt, 'status' | 'responder' | 'responded_at'>;

const STATUS_TEXT: Readonly<Record<Exclude<InboxWaitpointStatus, 'responded'>, MessageKey>> = {
  awaiting: 'inbox.awaiting',
  processing: 'inbox.processing',
  not_awaited: 'inbox.notAwaited',
};

const WHO: Readonly<Record<ReturnType<typeof responderLabel>, MessageKey>> = {
  you: 'inbox.whoYou',
  agent: 'inbox.whoAgent',
  someone: 'inbox.whoSomeone',
};

function Button(props: {
  readonly ui: RelayUi;
  readonly label: string;
  readonly accessibilityLabel: string;
  readonly role: 'button' | 'link';
  readonly onPress: () => void;
  readonly testID: string;
}) {
  const { theme } = props.ui;
  return (
    <Pressable
      testID={props.testID}
      onPress={props.onPress}
      accessibilityRole={props.role}
      accessibilityLabel={props.accessibilityLabel}
      style={{
        minHeight: theme.minTouchTarget,
        minWidth: theme.minTouchTarget,
        paddingHorizontal: theme.spacing,
        justifyContent: 'center',
        borderRadius: theme.radius,
        borderWidth: 1,
        borderColor: theme.colors.primary,
      }}
    >
      <Text style={{ color: theme.colors.primary, fontSize: theme.fontSize - 2 }}>
        {props.label}
      </Text>
    </Pressable>
  );
}

// AG-35
// IN-6
// AG-32
/** The decision request of an inbox item. An approval item shows only the link to the Access approval surface. A response item shows its state: awaiting with its options as buttons, processing, responded with who and when, or no longer awaited. */
export function WaitpointPanel({ item, subscriberRecipientId, onOpenUrl }: WaitpointPanelProps) {
  const ui = useRelay();
  const { client, theme, t, locale } = ui;
  const [receipt, setReceipt] = useState<Receipt | null>(null);
  const [failed, setFailed] = useState(false);
  const waitpoint = item.waitpoint ?? null;

  if (isApprovalItem(item)) {
    const link = approvalLink(item);
    return (
      <View testID={`relay-approval-${item.id}`} style={{ marginTop: 8, gap: 8 }}>
        <Text style={{ color: theme.colors.textMuted, fontSize: theme.fontSize - 2 }}>
          {t('inbox.approvalNote')}
        </Text>
        {link !== null ? (
          <Button
            ui={ui}
            testID={`relay-approval-link-${item.id}`}
            role="link"
            label={t('inbox.approvalOpen')}
            accessibilityLabel={t('inbox.approvalOpen')}
            onPress={() => {
              openLink(link, onOpenUrl);
            }}
          />
        ) : null}
      </View>
    );
  }

  if (waitpoint === null) return null;

  const status = receipt?.status ?? waitpoint.status;
  const responder = receipt?.responder ?? waitpoint.responder;
  const respondedAt = receipt?.responded_at ?? waitpoint.responded_at;
  const line =
    status === 'responded'
      ? t('inbox.answeredBy', {
          who: t(WHO[responderLabel(responder, subscriberRecipientId)]),
          when: respondedAt ? formatDateTime(locale, respondedAt) : '',
        })
      : t(STATUS_TEXT[status]);
  const digest = waitpoint.subject_digest;
  const answerable = status === 'awaiting' && digest !== null && waitpoint.options.length > 0;

  const respond = (value: string) => {
    if (digest === null) return;
    setFailed(false);
    setReceipt({ status: 'processing' });
    void client.waitpoints
      .respond(waitpoint.id, value, digest)
      .then((answer) => {
        setReceipt(answer);
      })
      .catch(() => {
        setReceipt(null);
        setFailed(true);
      });
  };

  return (
    <View testID={`relay-waitpoint-${item.id}`} style={{ marginTop: 8, gap: 8 }}>
      <Text
        accessibilityLiveRegion="polite"
        style={{ color: theme.colors.text, fontSize: theme.fontSize - 2, fontWeight: '600' }}
      >
        {line}
      </Text>
      {answerable ? (
        <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
          {waitpoint.options.map((option) => (
            <Button
              key={option.value}
              ui={ui}
              testID={`relay-waitpoint-option-${item.id}-${option.value}`}
              role="button"
              label={option.label}
              accessibilityLabel={t('inbox.respond', { option: option.label })}
              onPress={() => {
                respond(option.value);
              }}
            />
          ))}
        </View>
      ) : null}
      {failed ? (
        <Text
          accessibilityRole="alert"
          accessibilityLiveRegion="polite"
          style={{ color: theme.colors.danger, fontSize: theme.fontSize - 2 }}
        >
          {t('inbox.actionFailed')}
        </Text>
      ) : null}
    </View>
  );
}
