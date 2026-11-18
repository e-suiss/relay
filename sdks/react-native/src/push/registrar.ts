import type { RelayHttp } from '../http';
import type { KeyValueStore, Logger } from '../ports';
import type {
  Device,
  DeviceInterruptionPermission,
  DeviceInterruptionPermissions,
  DeviceRegistration,
} from '../types';
import type { InterruptionCapabilities, InterruptionCapability, PushAdapter } from './adapter';
import { androidChannels, provisionalAllowed, type CategoryDefinition } from './channels';
import type { PushPlatform } from './payload';

const KEY_DEVICE = 'relay.device.id';
const KEY_TOKEN = 'relay.device.token';
const KEY_SIGNATURE = 'relay.device.signature';

export type RegistrationReason = 'start' | 'foreground' | 'token_refresh';

export interface RegistrarOptions {
  readonly categories: readonly CategoryDefinition[];
  readonly locale?: () => string | undefined;
  readonly timezone?: () => string | undefined;
}

const UNSUPPORTED: InterruptionCapabilities = {
  dndAccess: 'unsupported',
  criticalAlerts: 'unsupported',
  timeSensitive: 'unsupported',
};

const reported = (value: InterruptionCapability): DeviceInterruptionPermission | undefined =>
  value === 'unsupported' ? undefined : value;

// CH-65
/** The interruption permissions a registration reports: Critical Alerts and time-sensitive on iOS, Do Not Disturb access on Android; `null` when there is nothing to report, which keeps the level Relay holds. */
export function interruptionPermissions(
  platform: PushPlatform,
  capabilities: InterruptionCapabilities,
): DeviceInterruptionPermissions | null {
  const fields =
    platform === 'apns'
      ? {
          critical_alerts: reported(capabilities.criticalAlerts),
          time_sensitive: reported(capabilities.timeSensitive),
        }
      : { dnd_access: reported(capabilities.dndAccess) };
  const permissions = Object.fromEntries(
    Object.entries(fields).filter((entry) => entry[1] !== undefined),
  ) as DeviceInterruptionPermissions;
  return Object.keys(permissions).length > 0 ? permissions : null;
}

/** Registers and refreshes the push token of this device with `devices:write`, and reports the OS permission, the interruption permissions and Android channels on every start. */
export class DeviceRegistrar {
  private unsubscribe: (() => void) | null = null;
  private deviceId: string | null = null;

  constructor(
    private readonly http: RelayHttp,
    private readonly adapter: PushAdapter,
    private readonly store: KeyValueStore,
    private readonly logger: Logger,
    private readonly options: RegistrarOptions,
  ) {}

  // CH-28
  // CH-30
  // CH-31
  // X-31
  /** Creates the Android channels, listens for token refreshes and registers the device. */
  async start(): Promise<Device | null> {
    if (this.isAndroid() && this.adapter.createAndroidChannels) {
      await this.adapter.createAndroidChannels(androidChannels(this.options.categories));
    }
    this.unsubscribe ??= this.adapter.onTokenRefresh((token) => {
      void this.register('token_refresh', token).catch(() => {
        this.logger.warn('relay.device.refresh_failed');
      });
    });
    return this.register('start');
  }

  stop(): void {
    this.unsubscribe?.();
    this.unsubscribe = null;
  }

  // CH-29
  /** Asks the OS for permission: provisional only when every starting class is marketing or social. */
  async requestPermission(): Promise<Device | null> {
    const provisional =
      this.adapter.platform === 'apns' &&
      provisionalAllowed(this.options.categories.map((category) => category.class));
    await this.adapter.requestPermission({ provisional });
    return this.register('foreground');
  }

  /** The id Relay gave this device, once registered. */
  async currentDeviceId(): Promise<string | null> {
    this.deviceId ??= await this.store.getItem(KEY_DEVICE);
    return this.deviceId;
  }

  // CH-28
  // CH-31
  // CH-65
  /** Sends the token, permission, interruption permissions and channels; on `foreground` only when one of them changed since the last registration. */
  async register(reason: RegistrationReason, refreshedToken?: string): Promise<Device | null> {
    const token = refreshedToken ?? (await this.adapter.getToken());
    if (token === null || token === '') return null;
    const permission = await this.adapter.getPermission();
    const channels =
      this.isAndroid() && this.adapter.getAndroidChannels
        ? await this.adapter.getAndroidChannels()
        : undefined;
    const interruption = interruptionPermissions(
      this.adapter.platform,
      await this.interruptionCapabilities(),
    );
    const signature = JSON.stringify([token, permission, channels ?? null, interruption]);
    if (reason === 'foreground' && (await this.store.getItem(KEY_SIGNATURE)) === signature) {
      return null;
    }
    const previous = await this.store.getItem(KEY_TOKEN);
    const locale = this.options.locale?.();
    const timezone = this.options.timezone?.();
    const body: DeviceRegistration = {
      platform: this.adapter.platform,
      token,
      app: this.adapter.app,
      permission,
      ...(this.adapter.platform === 'apns'
        ? { apns_environment: this.adapter.apnsEnvironment ?? 'production' }
        : {}),
      ...(channels ? { android_channels: [...channels] } : {}),
      ...(locale ? { locale } : {}),
      ...(timezone ? { timezone } : {}),
      ...(interruption ? { interruption_permissions: interruption } : {}),
      ...(previous !== null && previous !== token ? { previous_token: previous } : {}),
    };
    const { body: device } = await this.http.request<Device>({
      method: 'POST',
      path: '/v1/subscriber/devices',
      body,
    });
    this.deviceId = device.id;
    await this.store.setItem(KEY_DEVICE, device.id);
    await this.store.setItem(KEY_TOKEN, token);
    await this.store.setItem(KEY_SIGNATURE, signature);
    this.logger.debug('relay.device.registered', {
      reason,
      permission,
      fingerprint: device.token_fingerprint,
    });
    return device;
  }

  /** Disables this device on sign-out; preferences stay. */
  async unregister(): Promise<void> {
    const id = await this.currentDeviceId();
    this.stop();
    if (id !== null) {
      await this.http.request<Device>({
        method: 'DELETE',
        path: '/v1/subscriber/devices/{device_id}',
        params: { device_id: id },
      });
    }
    this.deviceId = null;
    await this.store.removeItem(KEY_DEVICE);
    await this.store.removeItem(KEY_TOKEN);
    await this.store.removeItem(KEY_SIGNATURE);
  }

  // CH-65
  /** The DND access, Critical Alerts and time-sensitive permissions read through the adapter; everything is `unsupported` when the adapter cannot read them. */
  async interruptionCapabilities(): Promise<InterruptionCapabilities> {
    if (!this.adapter.getInterruptionCapabilities) return UNSUPPORTED;
    try {
      return await this.adapter.getInterruptionCapabilities();
    } catch {
      this.logger.debug('relay.device.interruption_unreadable');
      return UNSUPPORTED;
    }
  }

  private isAndroid(): boolean {
    return this.adapter.platform === 'fcm' || this.adapter.platform === 'hms';
  }
}
