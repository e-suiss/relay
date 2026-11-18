import 'dart:async';
import 'dart:convert';

import '../core/ports.dart';
import '../generated/models.dart';
import 'adapter.dart';
import 'payload.dart';
import 'receipts.dart';

/// Refreshes the counters after a sync signal and returns them.
typedef RelaySyncCallback = Future<InboxCounters?> Function(
  int? counterVersion,
);

// CH-32
// CH-33
// IN-35
// IN-38
/// Handles Relay pushes: fetches content-free content with a generic fallback, records receipts and removes notifications read elsewhere.
class RelayPushHandler {
  /// Creates the handler.
  RelayPushHandler({
    required this.adapter,
    required this.receipts,
    required this.store,
    required this.onSync,
    this.contentSource = const NoRelayPushContentSource(),
    this.locale,
    this.fetchTimeout = const Duration(seconds: 10),
    RelayLogger? logger,
  }) : logger = logger ?? const SilentRelayLogger();

  /// The platform push bridge.
  final RelayPushAdapter adapter;

  /// The receipt queue.
  final RelayReceiptQueue receipts;

  /// Durable storage for the notification index.
  final RelayKeyValueStore store;

  /// Refreshes the counters.
  final RelaySyncCallback onSync;

  /// Fetches content-free content.
  final RelayPushContentSource contentSource;

  /// The device locale for the generic text.
  final String? locale;

  /// How long a content fetch may take.
  final Duration fetchTimeout;

  /// The logger.
  final RelayLogger logger;

  static const String _indexKey = 'relay.push.index';
  static const int _indexSize = 100;

  /// Handles one push payload; [foreground] shows visible notifications the OS would not show itself.
  Future<RelayPushMessage?> handle(
    Map<Object?, Object?> payload, {
    bool foreground = false,
  }) async {
    final RelayPushMessage? message = parseRelayPush(adapter.platform, payload);
    switch (message) {
      case null:
        return null;
      case final RelayPushNotification n:
        await _notification(n, foreground);
      case RelayPushSync(:final int? counterVersion):
        await _sync(counterVersion);
      case final RelayPushRead r:
        await _read(r);
    }
    return message;
  }

  Future<void> _notification(RelayPushNotification n, bool foreground) async {
    if (!n.contentFree) {
      if (!foreground) return;
      final RelayNeutralText neutral = relayNeutralText(locale);
      await _show(
        n.deliveryId,
        n.title ?? neutral.title,
        n.body ?? neutral.body,
        n.url,
      );
      return;
    }
    RelayPushContent? content;
    try {
      content = await contentSource.fetch(n.deliveryId).timeout(fetchTimeout);
    } on Object {
      content = null;
    }
    if (content != null) {
      final String? ntf = content.notificationId;
      if (ntf != null) await _remember(ntf, n.deliveryId);
      await _show(n.deliveryId, content.title, content.body, content.url);
      return;
    }
    final RelayNeutralText fallback = relayNeutralText(locale);
    await _show(
      n.deliveryId,
      n.title ?? fallback.title,
      n.body ?? fallback.body,
      null,
    );
  }

  Future<void> _show(
    String deliveryId,
    String title,
    String body,
    String? url,
  ) async {
    await adapter.show(
      RelayLocalNotification(
        tag: deliveryId,
        title: title,
        body: body,
        url: url,
      ),
    );
    await displayed(deliveryId);
  }

  Future<Map<String, String>> _index() async {
    final String? raw = await store.read(_indexKey);
    if (raw == null) return <String, String>{};
    return (jsonDecode(raw) as Map<String, Object?>).map(
      (String k, Object? v) => MapEntry<String, String>(k, v! as String),
    );
  }

  Future<void> _remember(String notificationId, String deliveryId) async {
    final Map<String, String> index = await _index();
    index.remove(notificationId);
    index[notificationId] = deliveryId;
    while (index.length > _indexSize) {
      index.remove(index.keys.first);
    }
    await store.write(_indexKey, jsonEncode(index));
  }

  Future<void> _sync(int? counterVersion) async {
    InboxCounters? counters;
    try {
      counters = await onSync(counterVersion);
    } on Object {
      counters = null;
    }
    if (counters != null && counters.unread == 0) {
      final List<String> tags = (await adapter.shownTags())
          .where(isRelayDeliveryId)
          .toList();
      if (tags.isNotEmpty) await adapter.remove(tags);
    }
  }

  Future<void> _read(RelayPushRead read) async {
    final Map<String, String> index = await _index();
    final String? deliveryId = index[read.notificationId];
    if (deliveryId != null) {
      await adapter.remove(<String>[deliveryId]);
      return;
    }
    await _sync(read.counterVersion);
  }

  /// Records that a notification was shown.
  Future<void> displayed(String deliveryId) =>
      receipts.add(deliveryId, RelayReceipt.displayed);

  /// Records that the user opened a notification.
  Future<void> clicked(String deliveryId) =>
      receipts.add(deliveryId, RelayReceipt.clicked);
}
