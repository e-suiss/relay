import 'package:flutter/foundation.dart';

import '../generated/models.dart';

// IN-27
/// The local inbox: items with their state_version and the counters with their version; anything not newer than what is held is dropped.
class RelayInboxStore extends ChangeNotifier {
  final Map<String, InboxItem> _items = <String, InboxItem>{};
  final Map<String, int> _removed = <String, int>{};
  InboxCounters? _counters;

  /// The stream cursor to continue from.
  String? cursor;

  /// The list cursor of the next page.
  String? nextCursor;

  /// Whether more pages exist.
  bool hasMore = false;

  /// Whether the store has been filled by a cold sync.
  bool loaded = false;

  /// The counters.
  InboxCounters? get counters => _counters;

  /// The badge number (unseen).
  int get unseen => _counters?.unseen ?? 0;

  /// The visible items of the inbox tab, newest activity first.
  List<InboxItem> get items {
    final List<InboxItem> list = _items.values
        .where((InboxItem i) =>
            !i.hidden && !i.expired && !i.archived && i.snoozedUntil == null)
        .toList()
      ..sort((InboxItem a, InboxItem b) =>
          b.lastActivityAt.compareTo(a.lastActivityAt));
    return list;
  }

  /// Every held item, archived included.
  Iterable<InboxItem> get allItems => _items.values;

  /// One item.
  InboxItem? item(String id) => _items[id];

  /// The state_version held for an item.
  int? versionOf(String id) => _items[id]?.stateVersion ?? _removed[id];

  /// Applies counters when their version is newer.
  bool applyCounters(InboxCounters counters) {
    final InboxCounters? held = _counters;
    if (held != null && counters.version <= held.version) return false;
    _counters = counters;
    notifyListeners();
    return true;
  }

  /// Applies the counters an envelope carries.
  bool applyEnvelopeCounters(RealtimeEnvelopeCounters c) => applyCounters(
        InboxCounters(
          object: 'inbox_counters',
          unseen: c.unseen,
          unread: c.unread,
          total: c.total,
          version: c.version,
        ),
      );

  /// Replaces the contents with a cold sync's first page.
  void replaceAll(
    List<InboxItem> items, {
    InboxCounters? counters,
    String? cursor,
    String? nextCursor,
    bool hasMore = false,
  }) {
    final Map<String, InboxItem> previous = Map<String, InboxItem>.of(_items);
    _items.clear();
    for (final InboxItem i in items) {
      final InboxItem? old = previous[i.id];
      _items[i.id] = old != null && old.stateVersion > i.stateVersion ? old : i;
    }
    if (counters != null) {
      final InboxCounters? held = _counters;
      if (held == null || counters.version >= held.version) _counters = counters;
    }
    this.cursor = cursor ?? this.cursor;
    this.nextCursor = nextCursor;
    this.hasMore = hasMore;
    loaded = true;
    notifyListeners();
  }

  /// Adds a further page.
  void appendPage(List<InboxItem> items, {String? nextCursor, bool hasMore = false}) {
    for (final InboxItem i in items) {
      _upsert(i);
    }
    this.nextCursor = nextCursor;
    this.hasMore = hasMore;
    notifyListeners();
  }

  bool _upsert(InboxItem item) {
    final int? held = versionOf(item.id);
    if (held != null && item.stateVersion <= held) return false;
    _removed.remove(item.id);
    if (item.hidden || item.expired) {
      _items.remove(item.id);
      _removed[item.id] = item.stateVersion;
    } else {
      _items[item.id] = item;
    }
    return true;
  }

  /// Applies a full item when it is newer.
  bool upsert(InboxItem item) {
    final bool changed = _upsert(item);
    if (changed) notifyListeners();
    return changed;
  }

  /// Applies an item state when it is newer.
  bool applyState(InboxItemState state) =>
      applyChanges(state.id, state.stateVersion, state.toJson());

  /// Merges changed state fields into an item when the version is newer.
  bool applyChanges(String id, int version, Map<String, Object?> changes) {
    final InboxItem? old = _items[id];
    final int? held = versionOf(id);
    if (held != null && version <= held) return false;
    if (old == null) {
      if (changes['hidden'] == true || changes['expired'] == true) {
        _removed[id] = version;
      }
      return false;
    }
    final Map<String, Object?> json = <String, Object?>{
      ...old.toJson(),
      for (final MapEntry<String, Object?> e in changes.entries)
        if (old.toJson().containsKey(e.key) && e.key != 'id') e.key: e.value,
      'state_version': version,
    };
    return upsert(InboxItem.fromJson(json));
  }

  /// Applies an intent optimistically before the server answers; the version stays.
  void applyLocal(String id, String op, {String? snoozeUntil}) {
    final InboxItem? old = _items[id];
    if (old == null) return;
    final Map<String, Object?> json = old.toJson();
    final InboxCounters? c = _counters;
    int unseen = c?.unseen ?? 0;
    int unread = c?.unread ?? 0;
    switch (op) {
      case 'seen':
        if (!old.seen) unseen = unseen > 0 ? unseen - 1 : 0;
        json['seen'] = true;
      case 'read':
        if (!old.seen) unseen = unseen > 0 ? unseen - 1 : 0;
        if (!old.read) unread = unread > 0 ? unread - 1 : 0;
        json['seen'] = true;
        json['read'] = true;
      case 'unread':
        if (old.read) unread++;
        json['read'] = false;
      case 'archive':
        json['archived'] = true;
      case 'unarchive':
        json['archived'] = false;
      case 'hide':
        json['hidden'] = true;
      case 'snooze':
        json['snoozed_until'] = snoozeUntil;
      case 'unsnooze':
        json['snoozed_until'] = null;
    }
    _items[id] = InboxItem.fromJson(json);
    if (c != null) {
      _counters = InboxCounters(
        object: c.object,
        unseen: unseen,
        unread: unread,
        total: c.total,
        version: c.version,
      );
    }
    notifyListeners();
  }

  /// Clears everything (sign-out).
  void clear() {
    _items.clear();
    _removed.clear();
    _counters = null;
    cursor = null;
    nextCursor = null;
    hasMore = false;
    loaded = false;
    notifyListeners();
  }
}
