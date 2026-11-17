import 'dart:async';

import '../core/errors.dart';
import '../core/http.dart';
import '../core/ports.dart';
import '../generated/models.dart';
import '../generated/operations.dart';
import 'store.dart';

// IN-21
// IN-27
// IN-28
// IN-29
/// Keeps the local inbox in step with Relay: cold and delta syncs, buffered stream envelopes and the counter consistency report.
class RelayInboxSync {
  /// Creates the sync.
  RelayInboxSync({
    required this.http,
    required this.store,
    RelayLogger? logger,
    this.pageSize = 50,
  }) : logger = logger ?? const SilentRelayLogger();

  /// The HTTP core.
  final RelayHttp http;

  /// The local inbox.
  final RelayInboxStore store;

  /// The logger.
  final RelayLogger logger;

  /// Items per page.
  final int pageSize;

  bool _buffering = false;
  final List<Map<String, Object?>> _buffer = <Map<String, Object?>>[];
  Future<void>? _cold;

  /// Takes an envelope from the stream; buffered while a sync reads the list.
  void onEnvelope(Map<String, Object?> envelope) {
    if (_buffering) {
      _buffer.add(envelope);
      return;
    }
    _apply(envelope);
  }

  /// Notes a stream position without an envelope.
  void onCursor(String cursor) {
    if (!_buffering) store.cursor = cursor;
  }

  void _apply(Map<String, Object?> raw) {
    final RealtimeEnvelope envelope;
    try {
      envelope = RealtimeEnvelope.fromJson(raw);
    } on Object {
      logger.log(RelayLogLevel.warning, 'realtime.envelope_invalid');
      return;
    }
    store.applyEnvelopeCounters(envelope.counters);
    final String? id = envelope.id;
    if (id != null) store.cursor = id;
    final Map<String, Object?> d = envelope.d;
    switch (envelope.t) {
      case 'inbox.item_created':
        final Object? item = d['item'];
        if (item is! Map<String, Object?>) return;
        if (d['thin'] == true) {
          final Object? itemId = item['id'];
          if (itemId is String) unawaited(_fetch(itemId));
        } else {
          store.upsert(InboxItem.fromJson(item));
        }
      case 'inbox.item_updated':
        final Object? itemId = d['item_id'];
        final Object? version = d['state_version'];
        final Object? changes = d['changes'];
        if (itemId is String && version is int && changes is Map<String, Object?>) {
          store.applyChanges(itemId, version, changes);
        }
      case 'inbox.items_bulk_updated':
        unawaited(deltaSync().catchError((Object _) {}));
      case 'stream.resync_required':
        unawaited(coldSync().catchError((Object _) {}));
    }
  }

  Future<void> _fetch(String itemId) async {
    try {
      final RelayResponse r = await http.send(
        RelayOperation.getMyInboxItem,
        pathParams: <String, String>{'item_id': itemId},
      );
      store.upsert(InboxItem.fromJson(r.json));
    } on RelayNotFoundError {
      logger.log(RelayLogLevel.debug, 'inbox.item_gone');
    }
  }

  /// Asks for the counters unconditionally (IN-21).
  Future<void> refreshCounters() async {
    final RelayResponse r = await http.send(RelayOperation.getMyInboxCounters);
    store.applyCounters(InboxCounters.fromJson(r.json));
  }

  /// The first page with counters and cursor; stream envelopes that arrive meanwhile are applied after it.
  Future<void> coldSync() {
    return _cold ??= _coldSync().whenComplete(() {
      _cold = null;
    });
  }

  Future<void> _coldSync() async {
    _buffering = true;
    try {
      final RelayResponse r = await http.send(
        RelayOperation.listMyInboxItems,
        query: <String, String?>{'limit': '$pageSize'},
      );
      final InboxItemList page = InboxItemList.fromJson(r.json);
      store.replaceAll(
        page.data,
        counters: page.counters,
        cursor: page.cursor,
        nextCursor: page.nextCursor,
        hasMore: page.hasMore,
      );
    } finally {
      _buffering = false;
      final List<Map<String, Object?>> pending =
          List<Map<String, Object?>>.of(_buffer);
      _buffer.clear();
      pending.forEach(_apply);
    }
    await _checkConsistency();
  }

  Future<void> _checkConsistency() async {
    final InboxCounters? counters = store.counters;
    if (store.hasMore || counters == null) return;
    final int listed = store.items.where((InboxItem i) => !i.read).length;
    if (listed == counters.unread) return;
    final RelayResponse r =
        await http.send(RelayOperation.reportMyInboxInconsistency);
    store.applyCounters(InboxReconciliation.fromJson(r.json).counters);
  }

  /// The changes after the cursor; goes back to a cold sync when the cursor no longer holds.
  Future<void> deltaSync() async {
    String? since = store.cursor;
    if (since == null) return coldSync();
    _buffering = true;
    bool cold = false;
    try {
      while (true) {
        final RelayResponse r = await http.send(
          RelayOperation.listMyInboxChanges,
          query: <String, String?>{'since': since},
        );
        final InboxChanges changes = InboxChanges.fromJson(r.json);
        if (changes.truncated || changes.resyncRequired) {
          store.cursor = changes.cursor;
          cold = true;
          break;
        }
        for (final InboxChange c in changes.changes) {
          if (c.type == 'removed') {
            store.applyState(InboxItemState.fromJson(c.item));
          } else {
            store.upsert(InboxItem.fromJson(c.item));
          }
        }
        store.applyCounters(changes.counters);
        store.cursor = changes.cursor;
        since = changes.cursor;
        if (!changes.hasMore) break;
      }
    } finally {
      _buffering = false;
      final List<Map<String, Object?>> pending =
          List<Map<String, Object?>>.of(_buffer);
      _buffer.clear();
      pending.forEach(_apply);
    }
    if (cold) await coldSync();
  }

  /// A delta sync when the store holds a cursor, else a cold sync.
  Future<void> sync() =>
      store.loaded && store.cursor != null ? deltaSync() : coldSync();

  /// Loads the next page.
  Future<void> loadMore() async {
    final String? next = store.nextCursor;
    if (next == null) return;
    final RelayResponse r = await http.send(
      RelayOperation.listMyInboxItems,
      query: <String, String?>{'limit': '$pageSize', 'starting_after': next},
    );
    final InboxItemList page = InboxItemList.fromJson(r.json);
    store.appendPage(page.data, nextCursor: page.nextCursor, hasMore: page.hasMore);
  }

  /// Marks every unread item read, or one category.
  Future<void> markAllRead({String? category}) async {
    final RelayResponse r = await http.send(
      RelayOperation.markAllMyInboxRead,
      body: InboxReadAll(category: category).toJson(),
    );
    store.applyCounters(InboxReadAllResult.fromJson(r.json).counters);
    await deltaSync();
  }
}
