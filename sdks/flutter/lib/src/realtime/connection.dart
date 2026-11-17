import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/http.dart';
import '../core/ports.dart';
import 'transport.dart';

/// The state of the realtime connection.
enum RelayRealtimeStatus {
  /// Not started.
  idle,

  /// Connecting or reconnecting.
  connecting,

  /// Connected.
  connected,

  /// Stopped by the app.
  stopped,

  /// Stopped by the server (suspension, origin or connection limit).
  refused,
}

// IN-23
// IN-34
// IN-52
/// Keeps the inbox stream open: WebSocket first, then SSE, then long-poll, reconnecting with full-jitter backoff.
class RelayRealtime {
  /// Creates the connection.
  RelayRealtime({
    required this.transports,
    required this.http,
    required this.onEnvelope,
    required this.cursor,
    this.onCursor,
    this.deviceId,
    RelayRandom? random,
    RelayDelay? delay,
    RelayClock? clock,
    RelayLogger? logger,
    this.failuresBeforeFallback = 2,
    this.fallbackRetry = const Duration(minutes: 10),
  })  : random = random ?? SecureRelayRandom(),
        delay = delay ?? relayDefaultDelay,
        clock = clock ?? const SystemRelayClock(),
        logger = logger ?? const SilentRelayLogger();

  /// The transports in order of preference.
  final List<RelayRealtimeTransport> transports;

  /// The HTTP core (tokens).
  final RelayHttp http;

  /// Receives every envelope.
  final void Function(Map<String, Object?> envelope) onEnvelope;

  /// Receives cursor moves without envelopes.
  final void Function(String cursor)? onCursor;

  /// The cursor to resume after.
  final String? Function() cursor;

  /// The device holding the connection.
  final Future<String?> Function()? deviceId;

  /// Jitter source.
  final RelayRandom random;

  /// Waits between attempts.
  final RelayDelay delay;

  /// The clock.
  final RelayClock clock;

  /// The logger.
  final RelayLogger logger;

  /// Failed connects of one transport before falling back to the next.
  final int failuresBeforeFallback;

  /// How long a fallback transport is used before WebSocket is tried again.
  final Duration fallbackRetry;

  /// The connection state.
  final ValueNotifier<RelayRealtimeStatus> status =
      ValueNotifier<RelayRealtimeStatus>(RelayRealtimeStatus.idle);

  int _index = 0;
  int _generation = 0;
  bool _running = false;
  final Map<int, int> _failures = <int, int>{};
  Completer<bool>? _opened;
  Timer? _refreshTimer;
  RelayRealtimeTransport? _current;

  /// The transport in use.
  String get transport => transports[_index].name;

  /// Starts on the first transport; completes with whether it opened before the stream failed.
  Future<bool> start() {
    _generation++;
    _running = true;
    _index = 0;
    _failures.clear();
    final Completer<bool> opened = Completer<bool>();
    _opened = opened;
    status.value = RelayRealtimeStatus.connecting;
    unawaited(_loop(_generation));
    return opened.future;
  }

  void _settle(bool value) {
    final Completer<bool>? c = _opened;
    if (c != null && !c.isCompleted) c.complete(value);
  }

  Future<void> _loop(int generation) async {
    int attempt = 0;
    bool refreshed = false;
    bool alive() => _running && generation == _generation;
    while (alive()) {
      final RelayRealtimeTransport transport = transports[_index];
      _current = transport;
      bool opened = false;
      RelayRealtimeClosed? closed;
      DateTime? openedAt;
      bool restartOnWebSocket = false;
      try {
        final SubscriberToken token = await http.token();
        final String? device = deviceId == null ? null : await deviceId!();
        await for (final RelayRealtimeFrame frame in transport.open(
          token: token.token,
          cursor: cursor(),
          deviceId: device,
        )) {
          if (!alive()) break;
          switch (frame) {
            case RelayRealtimeOpened():
              opened = true;
              refreshed = false;
              attempt = 0;
              _failures[_index] = 0;
              openedAt = clock.now();
              status.value = RelayRealtimeStatus.connected;
              _scheduleRefresh(transport, token, generation);
              _settle(true);
            case RelayRealtimeEnvelopeFrame(:final Map<String, Object?> envelope):
              onEnvelope(envelope);
            case RelayRealtimeCursorFrame(cursor: final String c):
              onCursor?.call(c);
          }
          final DateTime? since = openedAt;
          if (_index > 0 &&
              since != null &&
              clock.now().difference(since) >= fallbackRetry) {
            restartOnWebSocket = true;
            break;
          }
        }
      } on RelayRealtimeClosed catch (c) {
        closed = c;
      } on Object catch (error) {
        closed = RelayRealtimeClosed('error: ${error.runtimeType}');
      } finally {
        _refreshTimer?.cancel();
        await transport.close();
      }
      if (!alive()) return;
      if (restartOnWebSocket) {
        _index = 0;
        continue;
      }
      status.value = RelayRealtimeStatus.connecting;
      logger.log(RelayLogLevel.debug, 'realtime.closed', <String, Object?>{
        'transport': transport.name,
        'reason': closed?.reason ?? 'ended',
      });
      if (closed != null && closed.fatal) {
        _running = false;
        status.value = RelayRealtimeStatus.refused;
        _settle(false);
        return;
      }
      if (closed != null && closed.refreshToken && !refreshed) {
        refreshed = true;
        try {
          await http.token(forceRefresh: true);
        } on Object {
          _settle(false);
        }
        continue;
      }
      if (!opened) {
        final int failures = (_failures[_index] ?? 0) + 1;
        _failures[_index] = failures;
        if (failures >= failuresBeforeFallback && _index < transports.length - 1) {
          _index++;
        } else if (_index == transports.length - 1) {
          _settle(false);
        }
      }
      final Duration backoff = relayBackoff(attempt, random);
      final Duration? retryAfter = closed?.retryAfter;
      attempt++;
      await delay(retryAfter != null && retryAfter > backoff ? retryAfter : backoff);
    }
  }

  void _scheduleRefresh(
    RelayRealtimeTransport transport,
    SubscriberToken token,
    int generation,
  ) {
    _refreshTimer?.cancel();
    final DateTime? expiresAt = token.expiresAt;
    Duration wait = const Duration(minutes: 10);
    if (expiresAt != null) {
      wait = expiresAt.difference(clock.now()) - const Duration(seconds: 60);
      if (wait.isNegative) wait = Duration.zero;
    }
    _refreshTimer = Timer(wait, () {
      if (!_running || generation != _generation) return;
      unawaited(() async {
        try {
          final SubscriberToken fresh = await http.token(forceRefresh: true);
          if (_current == transport) await transport.refreshToken(fresh.token);
          _scheduleRefresh(transport, fresh, generation);
        } on Object {
          logger.log(RelayLogLevel.warning, 'realtime.token_refresh_failed');
        }
      }());
    });
  }

  /// Closes the connection (app in background or sign-out).
  Future<void> stop() async {
    _running = false;
    _generation++;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _settle(false);
    final RelayRealtimeTransport? t = _current;
    _current = null;
    await t?.close();
    status.value = RelayRealtimeStatus.stopped;
  }
}
