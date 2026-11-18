import '../generated/models.dart';

final RegExp _deliveryId = RegExp(r'^dlv_[0-7][0-9a-hjkmnp-tv-z]{25}$');
final RegExp _notificationId = RegExp(r'^ntf_[0-7][0-9a-hjkmnp-tv-z]{25}$');

/// Whether a value is a delivery identifier.
bool isRelayDeliveryId(String value) => _deliveryId.hasMatch(value);

/// A Relay push as the SDK understands it.
sealed class RelayPushMessage {
  const RelayPushMessage();
}

/// A visible notification; content-free ones carry only the opaque delivery id.
class RelayPushNotification extends RelayPushMessage {
  /// Creates a notification.
  const RelayPushNotification({
    required this.deliveryId,
    required this.contentFree,
    this.topic,
    this.url,
    this.title,
    this.body,
  });

  /// The delivery identifier.
  final String deliveryId;

  /// Whether the content must be fetched.
  final bool contentFree;

  /// The subject key.
  final String? topic;

  /// The target link.
  final String? url;

  /// The shown title.
  final String? title;

  /// The shown body.
  final String? body;
}

/// A sync signal; it never carries inbox content.
class RelayPushSync extends RelayPushMessage {
  /// Creates a sync signal.
  const RelayPushSync({this.counterVersion});

  /// The counter version of the change.
  final int? counterVersion;
}

/// A read on another device.
class RelayPushRead extends RelayPushMessage {
  /// Creates a read signal.
  const RelayPushRead({required this.notificationId, this.counterVersion});

  /// The notification read elsewhere.
  final String notificationId;

  /// The counter version of the change.
  final int? counterVersion;
}

String? _string(Object? v) => v is String && v.isNotEmpty ? v : null;

Object? _normalize(Object? v) {
  if (v is Map<Object?, Object?>) {
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> e in v.entries)
        e.key.toString(): _normalize(e.value),
    };
  }
  if (v is List<Object?>) {
    return <Object?>[for (final Object? e in v) _normalize(e)];
  }
  return v;
}

// CH-33
// CH-67
// IN-35
// IN-38
/// Parses a push payload; returns null for a payload that is not a valid Relay push.
RelayPushMessage? parseRelayPush(
  DevicePlatform platform,
  Map<Object?, Object?> raw,
) {
  final Map<String, Object?> payload = _normalize(raw)! as Map<String, Object?>;
  switch (platform) {
    case DevicePlatform.apns:
      return _apns(payload);
    case DevicePlatform.fcm:
    case DevicePlatform.hms:
      return _fcm(payload);
    case DevicePlatform.webPush:
    case DevicePlatform.unifiedPush:
    case DevicePlatform.unrecognized:
      return null;
  }
}

RelayPushMessage? _apns(Map<String, Object?> payload) {
  final Object? relay = payload['relay'];
  if (relay is! Map<String, Object?>) return null;
  final Object? aps = payload['aps'];
  final Map<String, Object?> apsMap = aps is Map<String, Object?>
      ? aps
      : const <String, Object?>{};
  if (relay['sync'] == true) {
    final Object? v = relay['counter_version'];
    if (v != null && v is! int) return null;
    return RelayPushSync(counterVersion: v as int?);
  }
  final String? id = _string(relay['id']);
  if (id == null || !_deliveryId.hasMatch(id)) return null;
  final Object? alert = apsMap['alert'];
  String? title;
  String? body;
  if (alert is Map<String, Object?>) {
    title = _string(alert['title']);
    body = _string(alert['body']);
  } else if (alert is String) {
    body = alert;
  }
  final bool contentFree =
      apsMap['mutable-content'] == 1 &&
      relay.keys.every((String k) => k == 'id');
  return RelayPushNotification(
    deliveryId: id,
    contentFree: contentFree,
    topic: _string(relay['topic']),
    url: _string(relay['url']),
    title: title,
    body: body,
  );
}

RelayPushMessage? _fcm(Map<String, Object?> payload) {
  final Object? data = payload['data'];
  if (data is! Map<String, Object?>) return null;
  if (data['relay_sync'] == '1') {
    final Object? raw = data['relay_counter_version'];
    int? version;
    if (raw != null) {
      if (raw is! String || !RegExp(r'^\d+$').hasMatch(raw)) return null;
      version = int.parse(raw);
    }
    final Object? read = data['relay_read'];
    if (read == null) return RelayPushSync(counterVersion: version);
    if (read is! String || !_notificationId.hasMatch(read)) return null;
    return RelayPushRead(notificationId: read, counterVersion: version);
  }
  final String? id = _string(data['relay_id']);
  if (id == null || !_deliveryId.hasMatch(id)) return null;
  final Object? notification = payload['notification'];
  final bool contentFree = notification is! Map<String, Object?>;
  final String? title = notification is Map<String, Object?>
      ? _string(notification['title'])
      : _string(data['relay_neutral_title']);
  final String? body = notification is Map<String, Object?>
      ? _string(notification['body'])
      : _string(data['relay_neutral_body']);
  return RelayPushNotification(
    deliveryId: id,
    contentFree: contentFree,
    topic: _string(data['relay_topic']),
    url: _string(data['relay_url']),
    title: title,
    body: body,
  );
}

/// The generic text shown when content cannot be fetched.
class RelayNeutralText {
  /// Creates the text.
  const RelayNeutralText(this.title, this.body);

  /// The title.
  final String title;

  /// The body.
  final String body;
}

// CH-33
/// The generic fallback text for a locale: Turkish for tr, English otherwise.
RelayNeutralText relayNeutralText(String? locale) {
  final String lang = (locale ?? '').toLowerCase().split(RegExp('[-_]')).first;
  return lang == 'tr'
      ? const RelayNeutralText('Yeni bildirim', 'Yeni bir bildiriminiz var.')
      : const RelayNeutralText(
          'New notification',
          'You have a new notification.',
        );
}
