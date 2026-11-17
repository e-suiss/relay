import { useCallback, useEffect, useRef, useState } from 'react';
import { FlatList, Pressable, Text, View } from 'react-native';
import { inTab, type InboxTab } from '../inbox/store';
import type { InboxIntentOp, InboxItem } from '../types';
import { useInbox, useRelay, type RelayUi } from './context';

export const UNDO_WINDOW_MS = 5_000;

export interface InboxListProps {
  readonly tab?: InboxTab;
  readonly onOpenItem?: (item: InboxItem) => void;
  readonly undoWindowMs?: number;
  readonly testID?: string;
}

interface PendingUndo {
  readonly itemId: string;
  readonly op: 'archive' | 'hide';
  readonly handle: unknown;
}

function Action(props: {
  readonly ui: RelayUi;
  readonly label: string;
  readonly onPress: () => void;
  readonly testID: string;
}) {
  const { theme } = props.ui;
  return (
    <Pressable
      testID={props.testID}
      onPress={props.onPress}
      accessibilityRole="button"
      accessibilityLabel={props.label}
      style={{
        minHeight: theme.minTouchTarget,
        minWidth: theme.minTouchTarget,
        paddingHorizontal: theme.spacing,
        justifyContent: 'center',
        borderRadius: theme.radius,
        borderWidth: 1,
        borderColor: theme.colors.border,
      }}
    >
      <Text style={{ color: theme.colors.primary, fontSize: theme.fontSize - 2 }}>
        {props.label}
      </Text>
    </Pressable>
  );
}

// X-32
// IN-12
// IN-15
/** The inbox list: read, unread, archive and hide, with a short undo buffer before archive and hide reach Relay. Unread is shown by a dot and a text label, never by colour alone. */
export function InboxList({ tab = 'inbox', onOpenItem, undoWindowMs, testID }: InboxListProps) {
  const ui = useRelay();
  const { client, theme, t } = ui;
  const snapshot = useInbox();
  const [undo, setUndo] = useState<PendingUndo | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const undoRef = useRef<PendingUndo | null>(null);
  const undoMs = undoWindowMs ?? UNDO_WINDOW_MS;

  const now = client.now;
  const items = snapshot.items.filter((item) => inTab(item, tab, now));

  const send = useCallback(
    (itemId: string, op: InboxIntentOp) => {
      void client
        .intent(itemId, op, { interactive: true })
        .then((result) => {
          if (result.conflicts.some((conflict) => conflict.notify))
            setNotice(t('inbox.updatedElsewhere'));
        })
        .catch(() => undefined);
    },
    [client, t],
  );

  const commitUndo = useCallback(() => {
    const pending = undoRef.current;
    if (!pending) return;
    undoRef.current = null;
    setUndo(null);
    send(pending.itemId, pending.op);
  }, [send]);

  const delayed = useCallback(
    (itemId: string, op: 'archive' | 'hide') => {
      commitUndo();
      const handle = setTimeout(commitUndo, undoMs);
      const pending = { itemId, op, handle };
      undoRef.current = pending;
      setUndo(pending);
    },
    [commitUndo, undoMs],
  );

  const cancelUndo = useCallback(() => {
    const pending = undoRef.current;
    if (!pending) return;
    clearTimeout(pending.handle as ReturnType<typeof setTimeout>);
    undoRef.current = null;
    setUndo(null);
  }, []);

  useEffect(
    () => () => {
      const pending = undoRef.current;
      if (pending) {
        clearTimeout(pending.handle as ReturnType<typeof setTimeout>);
        undoRef.current = null;
        void client
          .intent(pending.itemId, pending.op, { interactive: true })
          .catch(() => undefined);
      }
    },
    [client],
  );

  const visible = items.filter((item) => item.id !== undo?.itemId);

  return (
    <View
      testID={testID ?? 'relay-inbox-list'}
      style={{ flex: 1, backgroundColor: theme.colors.background }}
    >
      <View
        style={{
          flexDirection: 'row',
          justifyContent: 'space-between',
          alignItems: 'center',
          padding: theme.spacing,
        }}
      >
        <Text
          accessibilityRole="header"
          style={{ color: theme.colors.text, fontSize: theme.fontSize + 4, fontWeight: '700' }}
        >
          {t('inbox.title')}
        </Text>
        <Action
          ui={ui}
          testID="relay-inbox-read-all"
          label={t('inbox.readAll')}
          onPress={() => {
            void client.sync.readAll().catch(() => undefined);
          }}
        />
      </View>
      {notice !== null ? (
        <Text
          accessibilityLiveRegion="polite"
          accessibilityRole="alert"
          style={{ color: theme.colors.text, padding: theme.spacing }}
        >
          {notice}
        </Text>
      ) : null}
      <FlatList
        data={visible}
        keyExtractor={(item) => item.id}
        accessibilityRole="list"
        ListEmptyComponent={
          <Text
            style={{
              color: theme.colors.textMuted,
              padding: theme.spacing,
              fontSize: theme.fontSize,
            }}
          >
            {snapshot.ready ? t('inbox.empty') : t('inbox.loading')}
          </Text>
        }
        renderItem={({ item }) => {
          const state = item.read ? t('inbox.read') : t('inbox.unread');
          const title = item.title ?? '';
          return (
            <View
              testID={`relay-inbox-item-${item.id}`}
              style={{
                padding: theme.spacing,
                borderBottomWidth: 1,
                borderBottomColor: theme.colors.border,
                backgroundColor: item.read ? theme.colors.background : theme.colors.surface,
              }}
            >
              <Pressable
                onPress={() => {
                  if (!item.read) send(item.id, 'read');
                  onOpenItem?.(item);
                }}
                accessibilityRole="button"
                accessibilityLabel={t('inbox.item', { title, state })}
                style={{ minHeight: theme.minTouchTarget }}
              >
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                  {!item.read ? (
                    <View
                      importantForAccessibility="no"
                      style={{
                        width: 8,
                        height: 8,
                        borderRadius: 4,
                        backgroundColor: theme.colors.primary,
                      }}
                    />
                  ) : null}
                  <Text
                    style={{
                      color: theme.colors.text,
                      fontSize: theme.fontSize,
                      fontWeight: item.read ? '400' : '700',
                      flex: 1,
                    }}
                  >
                    {title}
                  </Text>
                  <Text style={{ color: theme.colors.textMuted, fontSize: theme.fontSize - 4 }}>
                    {state}
                  </Text>
                </View>
                {item.body ? (
                  <Text
                    style={{ color: theme.colors.textMuted, fontSize: theme.fontSize - 2 }}
                    numberOfLines={3}
                  >
                    {item.body}
                  </Text>
                ) : null}
              </Pressable>
              <View style={{ flexDirection: 'row', gap: 8, marginTop: 8, flexWrap: 'wrap' }}>
                <Action
                  ui={ui}
                  testID={`relay-inbox-toggle-read-${item.id}`}
                  label={item.read ? t('inbox.markUnread') : t('inbox.markRead')}
                  onPress={() => {
                    send(item.id, item.read ? 'unread' : 'read');
                  }}
                />
                <Action
                  ui={ui}
                  testID={`relay-inbox-archive-${item.id}`}
                  label={item.archived ? t('inbox.unarchive') : t('inbox.archive')}
                  onPress={() => {
                    if (item.archived) send(item.id, 'unarchive');
                    else delayed(item.id, 'archive');
                  }}
                />
                <Action
                  ui={ui}
                  testID={`relay-inbox-hide-${item.id}`}
                  label={t('inbox.hide')}
                  onPress={() => {
                    delayed(item.id, 'hide');
                  }}
                />
              </View>
            </View>
          );
        }}
      />
      {undo !== null ? (
        <View
          accessibilityLiveRegion="polite"
          style={{
            flexDirection: 'row',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: theme.spacing,
            backgroundColor: theme.colors.surface,
          }}
        >
          <Text style={{ color: theme.colors.text }}>
            {undo.op === 'archive' ? t('inbox.archived') : t('inbox.hidden')}
          </Text>
          <Action ui={ui} testID="relay-inbox-undo" label={t('inbox.undo')} onPress={cancelUndo} />
        </View>
      ) : null}
    </View>
  );
}
