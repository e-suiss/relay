import type { AndroidChannel, DevicePermission } from '../types';
import type { AndroidChannelSpec } from './channels';
import type { PushPlatform } from './payload';

export type InterruptionCapability = 'granted' | 'denied' | 'not_determined' | 'unsupported';

/** Interruption permissions the platform grants beyond the notification permission; `unsupported` is never reported. */
export interface InterruptionCapabilities {
  readonly dndAccess: InterruptionCapability;
  readonly criticalAlerts: InterruptionCapability;
  readonly timeSensitive: InterruptionCapability;
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

/** Fetches the content of a content-free push by its delivery id; `null` means it could not be fetched. The default fetches it from Relay. */
export interface PushContentSource {
  fetch(deliveryId: string): Promise<PushContent | null>;
}

export interface PushContent {
  readonly title?: string | null;
  readonly body?: string | null;
  readonly url?: string | null;
  readonly notificationId?: string | null;
}

export const noPushContent: PushContentSource = {
  fetch: () => Promise.resolve(null),
};
