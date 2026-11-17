export { createRelayClient, RelayClient } from './client';
export type { RelayClientOptions, RelayPushOptions } from './client';
export {
  RelayAuthError,
  RelayBoundaryError,
  RelayConflictError,
  RelayError,
  RelayIdempotencyError,
  RelayNetworkError,
  RelayNotFoundError,
  RelayRateLimitError,
  RelayServerError,
  RelayValidationError,
  isRetryable,
} from './errors';
export type { Problem } from './errors';
export { ALLOWED_OPERATIONS } from './boundary';
export { MESSAGES, resolveLocale, translate } from './i18n';
export type { MessageKey, RelayLocale } from './i18n';
export { inTab, InboxStore } from './inbox/store';
export type { InboxSnapshot, InboxTab } from './inbox/store';
export type { FlushResult, IntentConflict } from './inbox/queue';
export { API_VERSION, cryptoRandom, memoryStore, silentLogger, systemClock } from './ports';
export type {
  Clock,
  FetchLike,
  KeyValueStore,
  Logger,
  Random,
  SubscriberToken,
  TokenProvider,
} from './ports';
export { DEVICE_SIGNALS, statusTtl } from './presence';
export type { DeviceSignalName, DeviceSignals } from './presence';
export { noPushContent } from './push/adapter';
export type {
  DisplayedNotification,
  InterruptionCapabilities,
  LocalNotification,
  PushAdapter,
  PushContent,
  PushContentSource,
} from './push/adapter';
export { androidChannelId, androidChannels, provisionalAllowed } from './push/channels';
export type {
  AndroidChannelSpec,
  CategoryDefinition,
  InterruptionLevel,
  MessageClass,
} from './push/channels';
export { parsePush } from './push/payload';
export type { NotificationPush, PushPlatform, ReadPush, RelayPush, SyncPush } from './push/payload';
export type { Presentation, ShownNotification } from './push/handler';
export type { ConnectionState } from './realtime/connection';
export type { StreamingConnector } from './realtime/sse';
export type { WebSocketFactory, WebSocketLike } from './realtime/websocket';
export type * from './types';
export { RelayProvider, useInbox, useRelay, useRelayLifecycle } from './ui/context';
export type { RelayProviderProps, RelayUi } from './ui/context';
export { InboxBell, badgeText } from './ui/InboxBell';
export type { InboxBellProps } from './ui/InboxBell';
export { InboxList } from './ui/InboxList';
export type { InboxListProps } from './ui/InboxList';
export { PreferenceCenter, cellDisplay } from './ui/PreferenceCenter';
export type { PreferenceCenterProps } from './ui/PreferenceCenter';
export { buildTheme, contrast, darkTheme, lightTheme } from './ui/theme';
export type { RelayBrand, RelayColors, RelayTheme } from './ui/theme';
