import { ConsentsClient } from './consents';
import { DisplayedNotificationReporter } from './displayed';
import { RelayHttp, TokenManager } from './http';
import { resolveLocale, type RelayLocale } from './i18n';
import { IntentQueue, type FlushResult } from './inbox/queue';
import { InboxStore } from './inbox/store';
import { InboxSync } from './inbox/sync';
import {
  cryptoRandom,
  silentLogger,
  systemClock,
  type Clock,
  type FetchLike,
  type KeyValueStore,
  type Logger,
  type Random,
  type TokenProvider,
} from './ports';
import { PreferencesClient } from './preferences';
import { DeviceStatusWriter } from './presence';
import type { PushAdapter, PushContentSource } from './push/adapter';
import type { CategoryDefinition } from './push/channels';
import { RelayPushContentSource } from './push/content';
import { PushHandler } from './push/handler';
import type { NotificationPush } from './push/payload';
import { ReceiptQueue } from './push/receipts';
import { DeviceRegistrar } from './push/registrar';
import { RealtimeConnection, type ConnectionState } from './realtime/connection';
import { PollTransport } from './realtime/poll';
import { SseTransport, xhrConnector, type StreamingConnector } from './realtime/sse';
import type { RealtimeTransport } from './realtime/transport';
import { WebSocketTransport, type WebSocketFactory } from './realtime/websocket';
import type { InboxIntentOp } from './types';
import { WaitpointsClient } from './waitpoints';

export interface RelayPushOptions {
  readonly adapter: PushAdapter;
  readonly categories: readonly CategoryDefinition[];
  /** Where the content of a content-free push comes from; Relay's push content endpoint by default. */
  readonly contentSource?: PushContentSource;
  /** The Android channel a data message is shown on; build it with `androidChannelId`. */
  readonly channelId?: (push: NotificationPush) => string | null;
}

export interface RelayClientOptions {
  /** The base address of the tenant's Relay data region, e.g. `https://relay.example.com`. */
  readonly baseUrl: string;
  /** Returns the subscriber token the host app obtained; called again with `forceRefresh` after a 401. */
  readonly tokenProvider: TokenProvider;
  /** Durable storage (AsyncStorage or a secure store) for the offline queue, receipts and device registration. */
  readonly storage: KeyValueStore;
  readonly push?: RelayPushOptions;
  readonly locale?: string;
  readonly timezone?: string;
  readonly realtime?: boolean;
  /** Reports the SHA-256 digests of the notification ids this device displays, so Relay can measure duplicate displays; off by default. */
  readonly reportDisplayedNotifications?: boolean;
  readonly fetch?: FetchLike;
  readonly webSocket?: WebSocketFactory;
  readonly streaming?: StreamingConnector;
  readonly clock?: Clock;
  readonly random?: Random;
  readonly logger?: Logger;
  readonly onConflicts?: (result: FlushResult) => void;
  readonly onRealtimeState?: (state: ConnectionState) => void;
}

const defaultWebSocket: WebSocketFactory = (url, protocols) => {
  const Socket = (globalThis as { WebSocket?: new (url: string, protocols: string[]) => unknown })
    .WebSocket;
  if (!Socket) throw new Error('WebSocket is not available');
  return new Socket(url, protocols) as ReturnType<WebSocketFactory>;
};

const defaultFetch: FetchLike = (input, init) => fetch(input, init);

/** The Relay client of one signed-in subscriber on this device. It never sends events, never writes the subscriber profile or consents and holds no secret credential. */
export class RelayClient {
  readonly http: RelayHttp;
  readonly inbox: InboxStore;
  readonly sync: InboxSync;
  readonly queue: IntentQueue;
  readonly receipts: ReceiptQueue;
  readonly displayedNotifications: DisplayedNotificationReporter | null;
  readonly presence: DeviceStatusWriter;
  readonly preferences: PreferencesClient;
  readonly consents: ConsentsClient;
  readonly waitpoints: WaitpointsClient;
  readonly devices: DeviceRegistrar | null;
  readonly push: PushHandler | null;
  readonly realtime: RealtimeConnection | null;
  readonly locale: RelayLocale;
  private readonly tokens: TokenManager;
  private readonly clock: Clock;
  private readonly storage: KeyValueStore;

  constructor(options: RelayClientOptions) {
    const clock = options.clock ?? systemClock;
    const random = options.random ?? cryptoRandom();
    const logger = options.logger ?? silentLogger;
    this.clock = clock;
    this.storage = options.storage;
    this.locale = resolveLocale(options.locale);
    this.tokens = new TokenManager(options.tokenProvider, clock);
    this.http = new RelayHttp({
      baseUrl: options.baseUrl,
      tokens: this.tokens,
      fetch: options.fetch ?? defaultFetch,
      clock,
      random,
      logger,
    });
    this.inbox = new InboxStore();
    this.queue = new IntentQueue(
      this.http,
      options.storage,
      this.inbox,
      random,
      logger,
      random.uuid(),
    );
    this.sync = new InboxSync({
      http: this.http,
      store: this.inbox,
      queue: this.queue,
      clock,
      logger,
      ...(options.onConflicts ? { onConflicts: options.onConflicts } : {}),
    });
    this.receipts = new ReceiptQueue(this.http, options.storage, clock, random, logger);
    this.displayedNotifications =
      options.reportDisplayedNotifications === true
        ? new DisplayedNotificationReporter(this.http, options.storage, clock, random, logger)
        : null;
    this.preferences = new PreferencesClient(this.http);
    this.consents = new ConsentsClient(this.http);
    this.waitpoints = new WaitpointsClient(this.http);
    this.devices = options.push
      ? new DeviceRegistrar(this.http, options.push.adapter, options.storage, logger, {
          categories: options.push.categories,
          locale: () => options.locale,
          timezone: () => options.timezone,
        })
      : null;
    const deviceId = () => this.devices?.currentDeviceId() ?? Promise.resolve(null);
    this.presence = new DeviceStatusWriter(this.http, deviceId, clock, logger);
    this.push = options.push
      ? this.pushHandler(options.push, options.storage, clock, logger)
      : null;
    this.realtime =
      options.realtime === false
        ? null
        : new RealtimeConnection(
            {
              transports: this.transports(options),
              tokens: this.tokens,
              clock,
              random,
              logger,
              cursor: () => this.inbox.streamCursor,
              deviceId,
            },
            {
              onOpen: () => {
                this.sync.opened();
              },
              onEnvelope: (envelope) => {
                this.sync.envelope(envelope);
              },
              ...(options.onRealtimeState ? { onStateChange: options.onRealtimeState } : {}),
            },
          );
    if (this.realtime) this.sync.attach(this.realtime);
  }

  // CH-28
  // IN-35
  /** Registers the device (when push is configured) and runs the first foreground sync. */
  async start(): Promise<void> {
    await this.devices?.start().catch(() => null);
    await this.sync.foreground();
    await this.receipts.flush();
    await this.displayedNotifications?.flush();
  }

  // IN-35
  // IN-21
  /** Call when the app returns to the foreground. */
  async foreground(): Promise<void> {
    await this.devices?.register('foreground').catch(() => null);
    await this.sync.foreground();
    await this.receipts.flush();
    await this.displayedNotifications?.flush();
  }

  // IN-35
  /** Call when the app goes to the background: the realtime connection closes and queued displayed-notification digests are reported. */
  background(): void {
    this.sync.background();
    void this.displayedNotifications?.flush().catch(() => undefined);
  }

  // OP-54
  // OP-95
  /** Queues the digest of a notification id the app displayed itself when `reportDisplayedNotifications` is on; does nothing otherwise. */
  async reportDisplayed(notificationId: string): Promise<void> {
    await this.displayedNotifications?.record(notificationId);
  }

  // IN-12
  // IN-13
  /** Queues an inbox intent, applies it on screen at once and sends the queue. */
  async intent(
    itemId: string,
    op: InboxIntentOp,
    options: { readonly interactive?: boolean; readonly snoozeUntil?: string } = {},
  ): Promise<FlushResult> {
    await this.queue.enqueue(itemId, op, options);
    return this.sync.flush();
  }

  /** Disables this device's push registration and forgets the local inbox state; call on sign-out. */
  async signOut(): Promise<void> {
    this.sync.background();
    this.presence.stop();
    this.displayedNotifications?.stop();
    await this.devices?.unregister().catch(() => undefined);
    this.inbox.clear();
    this.tokens.clear();
    for (const key of [
      'relay.inbox.intents',
      'relay.push.receipts',
      'relay.push.index',
      'relay.displayed.pending',
      'relay.displayed.batches',
    ]) {
      await this.storage.removeItem(key);
    }
  }

  get now(): number {
    return this.clock.now();
  }

  private pushHandler(
    push: RelayPushOptions,
    storage: KeyValueStore,
    clock: Clock,
    logger: Logger,
  ): PushHandler {
    const reporter = this.displayedNotifications;
    return new PushHandler({
      adapter: push.adapter,
      contentSource: push.contentSource ?? new RelayPushContentSource(this.http),
      receipts: this.receipts,
      store: storage,
      clock,
      logger,
      locale: () => this.locale,
      syncCounters: () => this.sync.refreshCounters(),
      ...(push.channelId ? { channelId: push.channelId } : {}),
      ...(reporter ? { displayed: (id: string) => reporter.record(id) } : {}),
    });
  }

  private transports(options: RelayClientOptions): RealtimeTransport[] {
    const clock = options.clock ?? systemClock;
    return [
      new WebSocketTransport(options.baseUrl, options.webSocket ?? defaultWebSocket, clock),
      new SseTransport(
        (deviceId) =>
          this.http.url('/v1/realtime/events', undefined, { device_id: deviceId ?? undefined }),
        options.streaming ?? xhrConnector(),
      ),
      new PollTransport(this.http),
    ];
  }
}

/** Creates the client of one signed-in subscriber. */
export function createRelayClient(options: RelayClientOptions): RelayClient {
  return new RelayClient(options);
}
