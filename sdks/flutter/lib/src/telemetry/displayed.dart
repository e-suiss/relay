import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../core/boundary.dart';
import '../core/errors.dart';
import '../core/http.dart';
import '../core/ports.dart';
import '../core/sha256.dart';

/// Starts calling a tick at every interval and returns a function that stops it; injectable so tests run without timers.
typedef RelayPeriodic = void Function() Function(Duration, void Function());

void Function() _timerPeriodic(Duration interval, void Function() tick) =>
    Timer.periodic(interval, (Timer _) => tick()).cancel;

// OP-95
/// The digest reported for a displayed notification: the lowercase hex SHA-256 of the identifier's UTF-8 bytes; the identifier itself is never sent.
String relayDisplayedDigest(String notificationId) =>
    relaySha256Hex(utf8.encode(notificationId));

class _Batch {
  _Batch(this.key, this.createdAt, this.notifications);

  final String key;
  final DateTime createdAt;
  final List<Map<String, String>> notifications;
}

// OP-54
// OP-95
/// Opt-in reporting of displayed notifications as identifier digests, so duplicates shown on the device can be measured; sent in batches of 20, every 30 seconds and when the app goes to the background, and a failed batch is retried with the same Idempotency-Key until it is 24 hours old.
class RelayDisplayedNotifications {
  /// Creates the reporter; nothing is queued or sent unless [enabled].
  RelayDisplayedNotifications({
    required this.http,
    this.enabled = false,
    RelayClock? clock,
    RelayPeriodic? periodic,
  }) : clock = clock ?? const SystemRelayClock(),
       periodic = periodic ?? _timerPeriodic;

  /// The HTTP core.
  final RelayHttp http;

  /// Whether displayed notifications are reported.
  final bool enabled;

  /// The clock.
  final RelayClock clock;

  /// Schedules the periodic flush.
  final RelayPeriodic periodic;

  /// The queue length that sends a batch at once.
  static const int flushSize = 20;

  /// The most notifications one request carries.
  static const int batchSize = 100;

  /// How often the queue is sent.
  static const Duration flushInterval = Duration(seconds: 30);

  /// How long a batch that could not be sent is kept.
  static const Duration maxAge = Duration(hours: 24);

  final List<Map<String, String>> _queue = <Map<String, String>>[];
  final List<_Batch> _batches = <_Batch>[];
  Future<void>? _flushing;
  void Function()? _stop;

  /// The notifications not sent yet.
  int get pending {
    int n = _queue.length;
    for (final _Batch b in _batches) {
      n += b.notifications.length;
    }
    return n;
  }

  /// Queues a notification the app displayed, by its Relay notification identifier; does nothing unless [enabled].
  Future<void> report(String notificationId) async {
    if (!enabled) return;
    _queue.add(<String, String>{
      'digest': relayDisplayedDigest(notificationId),
      'displayed_at': clock.now().toUtc().toIso8601String(),
    });
    _stop ??= periodic(flushInterval, _tick);
    if (_queue.length >= flushSize) await flush();
  }

  void _tick() {
    unawaited(flush());
  }

  /// Sends what is queued in requests of at most [batchSize]; a batch that fails is kept for the next flush.
  Future<void> flush() {
    return _flushing ??= _flush().whenComplete(() {
      _flushing = null;
    });
  }

  Future<void> _flush() async {
    final DateTime now = clock.now();
    while (_queue.isNotEmpty) {
      final int n = min(_queue.length, batchSize);
      final List<Map<String, String>> items = _queue.sublist(0, n);
      _queue.removeRange(0, n);
      _batches.add(_Batch(http.newIdempotencyKey(), now, items));
    }
    _batches.removeWhere((_Batch b) => now.difference(b.createdAt) > maxAge);
    while (_batches.isNotEmpty) {
      final _Batch batch = _batches.first;
      try {
        await http.sendPath(
          'POST',
          relayDisplayedNotificationsPath,
          name: 'recordMyDisplayedNotifications',
          idempotencyRequired: true,
          body: <String, Object?>{'notifications': batch.notifications},
          idempotencyKey: batch.key,
          retries: 0,
        );
      } on Object catch (error) {
        if (_keep(error)) return;
      }
      _batches.remove(batch);
    }
  }

  static bool _keep(Object error) =>
      error is! RelayError || error.retryable || error is RelayAuthError;

  /// Drops everything not sent yet, such as on sign-out.
  void clear() {
    _queue.clear();
    _batches.clear();
  }

  /// Stops the periodic flush.
  void dispose() {
    _stop?.call();
    _stop = null;
  }
}
