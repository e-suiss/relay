import type { AndroidChannel, DevicePermission } from '../types';
import type { AndroidChannelSpec } from './channels';
import type { PushPlatform } from './payload';

/** Interruption permissions the platform grants beyond the notification permission. */
export interface InterruptionCapabilities {
  readonly dndAccess: 'granted' | 'denied' | 'unsupported';
  readonly criticalAlerts: 'granted' | 'denied' | 'unsupported';
  readonly timeSensitive: 'granted' | 'denied' | 'unsupported';
}

/** A notification the SDK asks the platform to show. */
export interface LocalNotification {
  readonly deliveryId: string;
  readonly title: string;
  readonly body: string;
  readonly url: string | null;
  readonly channelId: string | null;
  readonly threadId: string | null;
}

/** A notification currently shown in the system tray. */
export interface DisplayedNotification {
  readonly deliveryId: string;
  readonly platformId: string;
}

/** Bridge to the app's push library (Firebase Messaging, Notifee, expo-notifications, a native module). The SDK depends on no push library itself. */
export interface PushAdapter {
  readonly platform: PushPlatform;
  readonly app: string;
  readonly apnsEnvironment?: 'production' | 'sandbox';
  getToken(): Promise<string | null>;
  onTokenRefresh(listener: (token: string) => void): () => void;
  getPermission(): Promise<DevicePermission>;
  requestPermission(options: { readonly provisional: boolean }): Promise<DevicePermission>;
  createAndroidChannels?(channels: readonly AndroidChannelSpec[]): Promise<void>;
  getAndroidChannels?(): Promise<readonly AndroidChannel[]>;
  getInterruptionCapabilities?(): Promise<InterruptionCapabilities>;
  displayNotification?(notification: LocalNotification): Promise<string>;
  getDisplayedNotifications?(): Promise<readonly DisplayedNotification[]>;
  removeDisplayedNotifications?(platformIds: readonly string[]): Promise<void>;
}

/** Fetches the content of a content-free push from the app's own backend or a future Relay endpoint; `null` means it could not be fetched. */
export interface PushContentSource {
  fetch(deliveryId: string): Promise<PushContent | null>;
}

export interface PushContent {
  readonly title: string;
  readonly body: string;
  readonly url?: string | null;
  readonly notificationId?: string | null;
}

export const noPushContent: PushContentSource = {
  fetch: () => Promise.resolve(null),
};
