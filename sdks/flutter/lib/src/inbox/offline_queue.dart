import 'dart:async';
import 'dart:convert';

import '../core/errors.dart';
import '../core/http.dart';
import '../core/ports.dart';
import '../generated/models.dart';
import '../generated/operations.dart';
import 'store.dart';

/// Intents that move an item back and need the current state_version.
const Set<String> relayReverseOps = <String>{'unread', 'unarchive', 'unsnooze'};

/// One queued intent.
class RelayQueuedIntent {
  /// Creates an entry.
  const RelayQueuedIntent({
    required this.itemId,
    required this.op,
    required this.clientSeq,
    required this.idempotencyKey,
    required this.session,
    this.baseStateVersion,
    this.snoozeUntil,
    this.interactive = false,
  });

  /// Reads an entry.
  factory RelayQueuedIntent.fromJson(Map<String, Object?> json) =>
      RelayQueuedIntent(
        itemId: json['item_id']! as String,
        op: json['op']! as String,
        clientSeq: (json['client_seq']! as num).toInt(),
        idempotencyKey: json['key']! as String,
        session: json['session']! as String,
        baseStateVersion: (json['base_state_version'] as num?)?.toInt(),
        snoozeUntil: json['snooze_until'] as String?,
        interactive: json['interactive'] == true,
      );

  /// The item.
  final String itemId;

  /// The intent.
  final String op;

  /// The queue sequence.
  final int clientSeq;

  /// The Idempotency-Key kept across resends.
  final String idempotencyKey;

  /// The app session that queued it.
  final String session;

  /// The state_version the intent was based on.
  final int? baseStateVersion;

  /// For snooze.
  final String? snoozeUntil;

  /// Whether the user made it on screen.
  final bool interactive;

  /// Writes the entry.
  Map<String, Object?> toJson() => <String, Object?>{
        'item_id': itemId,
        'op': op,
        'client_seq': clientSeq,
        'key': idempotencyKey,
        'session': session,
        'base_state_version': baseStateVersion,
        'snooze_until': snoozeUntil,
        'interactive': interactive,
      };
}

/// A notice that an on-screen reverse change lost to another device.
class RelayConflictNotice {
  /// Creates a notice.
  const RelayConflictNotice(this.itemId, this.op);

  /// The item.
  final String itemId;

  /// The intent that lost.
  final String op;
}

// IN-12
// IN-13
/// The durable offline queue of inbox intents: client_seq ordered, one intent per item, 409 accepted silently.
class RelayIntentQueue {
  /// Creates the queue.
  RelayIntentQueue({
    required this.http,
    required this.store,
    required this.inbox,
    RelayLogger? logger,
  })  : logger = logger ?? const SilentRelayLogger(),
        session = http.newIdempotencyKey();

  /// The HTTP core.
  final RelayHttp http;

  /// Durable storage.
  final RelayKeyValueStore store;

  /// The local inbox.
  final RelayInboxStore inbox;

  /// The logger.
  final RelayLogger logger;

  /// This app session.
  final String session;

  final StreamController<RelayConflictNotice> _notices =
      StreamController<RelayConflictNotice>.broadcast();

  /// Notices for on-screen reverse changes that lost to another device.
  Stream<RelayConflictNotice> get notices => _notices.stream;

  static const String _queueKey = 'relay.intents';
  static const String _seqKey = 'relay.intents.seq';

  Future<void>? _flushing;

  /// The queued entries in client_seq order.
  Future<List<RelayQueuedIntent>> entries() async {
    final String? raw = await store.read(_queueKey);
    if (raw == null) return <RelayQueuedIntent>[];
    final List<RelayQueuedIntent> list = <RelayQueuedIntent>[
      for (final Object? e in jsonDecode(raw) as List<Object?>)
        RelayQueuedIntent.fromJson(e! as Map<String, Object?>),
    ]..sort((RelayQueuedIntent a, RelayQueuedIntent b) =>
        a.clientSeq.compareTo(b.clientSeq));
    return list;
  }

  Future<void> _save(List<RelayQueuedIntent> list) async {
    if (list.isEmpty) {
      await store.remove(_queueKey);
    } else {
      await store.write(
        _queueKey,
        jsonEncode(<Object?>[for (final RelayQueuedIntent e in list) e.toJson()]),
      );
    }
  }

  Future<int> _nextSeq() async {
    final int next = int.parse(await store.read(_seqKey) ?? '0') + 1;
    await store.write(_seqKey, '$next');
    return next;
  }

  /// Queues an intent, replacing any earlier one for the item, and applies it locally.
  Future<void> enqueue(
    String itemId,
    String op, {
    String? snoozeUntil,
    bool interactive = false,
  }) async {
    final List<RelayQueuedIntent> list = await entries()
      ..removeWhere((RelayQueuedIntent e) => e.itemId == itemId);
    list.add(RelayQueuedIntent(
      itemId: itemId,
      op: op,
      clientSeq: await _nextSeq(),
      idempotencyKey: http.newIdempotencyKey(),
      session: session,
      baseStateVersion: inbox.versionOf(itemId),
      snoozeUntil: snoozeUntil,
      interactive: interactive,
    ));
    await _save(list);
    inbox.applyLocal(itemId, op, snoozeUntil: snoozeUntil);
  }

  /// Sends the queue in order; network and retryable failures keep the rest for later.
  Future<void> flush() {
    return _flushing ??= _flush().whenComplete(() {
      _flushing = null;
    });
  }

  Future<void> _done(RelayQueuedIntent e) async {
    final List<RelayQueuedIntent> list = await entries()
      ..removeWhere((RelayQueuedIntent x) =>
          x.itemId == e.itemId && x.clientSeq == e.clientSeq);
    await _save(list);
  }

  Future<void> _flush() async {
    while (true) {
      final List<RelayQueuedIntent> list = await entries();
      if (list.isEmpty) return;
      final RelayQueuedIntent e = list.first;
      final int? known = inbox.versionOf(e.itemId);
      final int? base = e.baseStateVersion;
      if (relayReverseOps.contains(e.op) &&
          known != null &&
          base != null &&
          known > base) {
        await _done(e);
        continue;
      }
      try {
        final RelayResponse response = await http.send(
          RelayOperation.applyMyInboxIntent,
          pathParams: <String, String>{'item_id': e.itemId},
          idempotencyKey: e.idempotencyKey,
          retries: 0,
          body: InboxIntent(
            op: e.op,
            clientSeq: e.clientSeq,
            baseStateVersion: relayReverseOps.contains(e.op) ? base : null,
            snoozeUntil: e.snoozeUntil,
          ).toJson(),
        );
        final InboxIntentResult result = InboxIntentResult.fromJson(response.json);
        inbox.applyState(result.state);
        inbox.applyCounters(result.counters);
      } on RelayConflictError catch (error) {
        final Object? current = error.problem['current'];
        if (current is Map<String, Object?>) {
          inbox.applyState(InboxItemState.fromJson(current));
        }
        if (e.interactive && e.session == session) {
          _notices.add(RelayConflictNotice(e.itemId, e.op));
        }
      } on RelayError catch (error) {
        if (error.retryable || error is RelayAuthError) return;
        logger.log(RelayLogLevel.debug, 'intent.dropped',
            <String, Object?>{'status': error.status, 'code': error.code});
      }
      await _done(e);
    }
  }

  /// Drops everything (sign-out).
  Future<void> clear() async {
    await store.remove(_queueKey);
  }
}
