import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as hc;

import 'core/http.dart';
import 'core/ports.dart';
import 'generated/models.dart';
import 'inbox/offline_queue.dart';
import 'inbox/store.dart';
import 'inbox/sync.dart';
import 'inbox/undo.dart';
import 'preferences/preferences.dart';
import 'presence/device_status.dart';
import 'push/adapter.dart';
import 'push/channels.dart';
import 'push/devices.dart';
import 'push/handler.dart';
import 'push/receipts.dart';
import 'realtime/connection.dart';
import 'realtime/io_websocket.dart';
import 'realtime/phoenix.dart';
import 'realtime/poll.dart';
import 'realtime/sse.dart';
import 'realtime/transport.dart';

// X-31
// IN-35
/// The Relay client of one signed-in subscriber.
class RelayClient {
  /// Creates the client; the host app supplies subscriber tokens and, for push, its platform bridge.
  RelayClient({
    required Uri baseUrl,
    required SubscriberTokenProvider tokenProvider,
    RelayKeyValueStore? store,
    RelayPushAdapter? push,
    List<RelayCategory> categories = const <RelayCategory>[],
    RelayPushContentSource contentSource = const NoRelayPushContentSource(),
    hc.Client? httpClient,
    RelayWebSocketConnector? webSocketConnector,
    List<RelayRealtimeTransport>? transports,
    RelayClock? clock,
    RelayRandom? random,
    RelayDelay? delay,
    RelayLogger? logger,
    this.locale,
    String? timezone,
    this.openTimeout = const Duration(seconds: 5),
  })  : store = store ?? MemoryRelayKeyValueStore(),
        clock = clock ?? const SystemRelayClock(),
        logger = logger ?? const SilentRelayLogger() {
    final RelayRandom rnd = random ?? SecureRelayRandom();
    final RelayDelay wait = delay ?? relayDefaultDelay;
    http = RelayHttp(
      baseUrl: baseUrl,
      tokenProvider: tokenProvider,
      client: httpClient,
      random: rnd,
      delay: wait,
      logger: this.logger,
      clock: this.clock,
    );
    sync = RelayInboxSync(http: http, store: inbox, logger: this.logger);
    intents = RelayIntentQueue(
      http: http,
      store: this.store,
      inbox: inbox,
      logger: this.logger,
    );
    receipts = RelayReceiptQueue(http: http, store: this.store, clock: this.clock);
    preferences = RelayPreferencesApi(http);
    final RelayPushAdapter? adapter = push;
    if (adapter != null) {
      devices = RelayDeviceRegistrar(
        http: http,
        adapter: adapter,
        store: this.store,
        categories: categories,
        locale: locale,
        timezone: timezone,
        logger: this.logger,
      );
      pushHandler = RelayPushHandler(
        adapter: adapter,
        receipts: receipts,
        store: this.store,
        contentSource: contentSource,
        locale: locale,
        logger: this.logger,
        onSync: (int? _) async {
          await sync.refreshCounters();
          return inbox.counters;
        },
      );
    }
    deviceStatus = RelayDeviceStatusWriter(
      http: http,
      deviceId: () async => devices?.deviceId(),
      clock: this.clock,
      delay: wait,
      logger: this.logger,
    );
    realtime = RelayRealtime(
      transports: transports ??
          <RelayRealtimeTransport>[
            RelayPhoenixTransport(
              baseUrl: baseUrl,
              connector: webSocketConnector ?? relayIoWebSocketConnector,
            ),
            RelaySseTransport(http: http),
            RelayPollTransport(http: http),
          ],
      http: http,
      onEnvelope: sync.onEnvelope,
      onCursor: sync.onCursor,
      cursor: () => inbox.cursor,
      deviceId: () async => devices?.deviceId(),
      random: rnd,
      delay: wait,
      clock: this.clock,
      logger: this.logger,
    );
  }

  /// Durable storage.
  final RelayKeyValueStore store;

  /// The clock.
  final RelayClock clock;

  /// The logger.
  final RelayLogger logger;

  /// The device locale.
  final String? locale;

  /// How long the foreground sequence waits for the stream to open.
  final Duration openTimeout;

  /// The HTTP core.
  late final RelayHttp http;

  /// The local inbox.
  final RelayInboxStore inbox = RelayInboxStore();

  /// The inbox sync.
  late final RelayInboxSync sync;

  /// The offline intent queue.
  late final RelayIntentQueue intents;

  /// The push receipt queue.
  late final RelayReceiptQueue receipts;

  /// The preferences.
  late final RelayPreferencesApi preferences;

  /// The device registrar, when a push adapter is set.
  RelayDeviceRegistrar? devices;

  /// The push handler, when a push adapter is set.
  RelayPushHandler? pushHandler;

  /// The device status writer.
  late final RelayDeviceStatusWriter deviceStatus;

  /// The realtime connection.
  late final RelayRealtime realtime;

  /// The undo buffer of the inbox widgets.
  final RelayUndoBuffer undo = RelayUndoBuffer();

  bool _foreground = false;

  /// Registers the device and runs the foreground sequence.
  Future<void> start() async {
    final RelayDeviceRegistrar? d = devices;
    if (d != null) {
      try {
        await d.start();
      } on Object catch (error) {
        logger.log(RelayLogLevel.warning, 'device.register_failed',
            <String, Object?>{'error': error.runtimeType.toString()});
      }
    }
    await foreground();
  }

  // IN-35
  /// Counters, then the stream, then a delta or cold sync, then the offline queue.
  Future<void> foreground() async {
    _foreground = true;
    try {
      await sync.refreshCounters();
    } on Object catch (error) {
      logger.log(RelayLogLevel.warning, 'inbox.counters_failed',
          <String, Object?>{'error': error.runtimeType.toString()});
    }
    if (!_foreground) return;
    await _waitOpen(realtime.start());
    try {
      await sync.sync();
      await intents.flush();
    } on Object catch (error) {
      logger.log(RelayLogLevel.warning, 'inbox.sync_failed',
          <String, Object?>{'error': error.runtimeType.toString()});
    }
    unawaited(receipts.flush().catchError((Object _) {}));
    final RelayDeviceRegistrar? d = devices;
    if (d != null) {
      unawaited(d.refreshIfChanged().catchError((Object _) => null));
    }
  }

  Future<void> _waitOpen(Future<bool> opened) {
    final Completer<void> done = Completer<void>();
    final Timer timer = Timer(openTimeout, () {
      if (!done.isCompleted) done.complete();
    });
    unawaited(opened.then((bool _) {
      timer.cancel();
      if (!done.isCompleted) done.complete();
    }));
    return done.future;
  }

  /// Closes the stream; freshness is left to push.
  Future<void> background() async {
    _foreground = false;
    await realtime.stop();
  }

  /// Sends an inbox intent through the offline queue.
  Future<void> intent(
    String itemId,
    String op, {
    String? snoozeUntil,
    bool interactive = true,
  }) async {
    await intents.enqueue(itemId, op,
        snoozeUntil: snoozeUntil, interactive: interactive);
    await intents.flush();
  }

  /// The permission the device reported last.
  DevicePermission? get pushPermission => devices?.permission;

  /// Signs out: disables the device and clears local state.
  Future<void> logout() async {
    await undo.flush();
    await realtime.stop();
    await devices?.unregister();
    await intents.clear();
    inbox.clear();
    http.clearToken();
  }

  /// Releases resources.
  Future<void> dispose() async {
    await realtime.stop();
    await devices?.dispose();
  }
}

/// Moves the client between foreground and background with the app lifecycle.
class RelayLifecycleObserver with WidgetsBindingObserver {
  /// Creates the observer.
  RelayLifecycleObserver(this.client);

  /// The client.
  final RelayClient client;

  /// Starts observing.
  void attach() => WidgetsBinding.instance.addObserver(this);

  /// Stops observing.
  void detach() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(client.foreground());
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(client.background());
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }
}
