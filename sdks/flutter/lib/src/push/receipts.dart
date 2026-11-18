import 'dart:convert';

import '../core/errors.dart';
import '../core/http.dart';
import '../core/ports.dart';
import '../generated/models.dart';
import '../generated/operations.dart';

/// A push receipt.
enum RelayReceipt {
  /// The notification was shown.
  displayed,

  /// The user opened it.
  clicked,
}

// CH-32
/// A durable queue of displayed and clicked receipts; a receipt survives being offline and is resent with the same Idempotency-Key.
class RelayReceiptQueue {
  /// Creates the queue.
  RelayReceiptQueue({
    required this.http,
    required this.store,
    RelayClock? clock,
  }) : clock = clock ?? const SystemRelayClock();

  /// The HTTP core.
  final RelayHttp http;

  /// Durable storage.
  final RelayKeyValueStore store;

  /// The clock.
  final RelayClock clock;

  static const String _key = 'relay.receipts';

  Future<void>? _flushing;

  Future<List<Map<String, Object?>>> _load() async {
    final String? raw = await store.read(_key);
    if (raw == null) return <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final Object? e in jsonDecode(raw) as List<Object?>)
        e! as Map<String, Object?>,
    ];
  }

  Future<void> _save(List<Map<String, Object?>> entries) async {
    if (entries.isEmpty) {
      await store.remove(_key);
    } else {
      await store.write(_key, jsonEncode(entries));
    }
  }

  /// The receipts still waiting.
  Future<int> get pending async => (await _load()).length;

  /// Queues a receipt and tries to send it.
  Future<void> add(String deliveryId, RelayReceipt receipt) async {
    final List<Map<String, Object?>> entries = await _load();
    entries.add(<String, Object?>{
      'key': http.newIdempotencyKey(),
      'body': PushReceipt(
        deliveryId: deliveryId,
        receipt: receipt.name,
        occurredAt: clock.now().toIso8601String(),
      ).toJson(),
    });
    await _save(entries);
    await flush();
  }

  /// Sends every queued receipt in order; stops at the first network or retryable failure.
  Future<void> flush() {
    return _flushing ??= _flush().whenComplete(() {
      _flushing = null;
    });
  }

  Future<void> _flush() async {
    List<Map<String, Object?>> entries = await _load();
    while (entries.isNotEmpty) {
      final Map<String, Object?> e = entries.first;
      try {
        await http.send(
          RelayOperation.recordMyPushReceipt,
          body: e['body'],
          idempotencyKey: e['key']! as String,
          retries: 0,
        );
      } on RelayError catch (error) {
        if (error.retryable || error is RelayAuthError) return;
      }
      entries = await _load();
      entries.removeAt(0);
      await _save(entries);
    }
  }
}
