import '../generated/models.dart';
import 'channels.dart';

/// Interruption permissions the platform reports; kept on the device because the registration has no field for them.
class RelayInterruptionCapabilities {
  /// Creates the capabilities.
  const RelayInterruptionCapabilities({
    this.dndAccess,
    this.criticalAlerts,
    this.timeSensitive,
  });

  /// Android: Do Not Disturb access granted.
  final bool? dndAccess;

  /// iOS: Critical Alerts authorised.
  final bool? criticalAlerts;

  /// iOS: time-sensitive notifications allowed.
  final bool? timeSensitive;
}

/// A notification the SDK asks the platform to show.
class RelayLocalNotification {
  /// Creates a notification.
  const RelayLocalNotification({
    required this.tag,
    required this.title,
    required this.body,
    this.url,
    this.channelId,
  });

  /// The tag: the delivery identifier.
  final String tag;

  /// The title.
  final String title;

  /// The body.
  final String body;

  /// The target link.
  final String? url;

  /// The Android channel.
  final String? channelId;
}

/// Bridges the SDK to the platform push SDK (FCM, APNs, HMS) chosen by the host app.
abstract interface class RelayPushAdapter {
  /// The push platform.
  DevicePlatform get platform;

  /// The app identifier (bundle id, package name or app id).
  String get appId;

  /// The APNs environment of the token; null on other platforms.
  ApnsEnvironment? get apnsEnvironment;

  /// The current push token.
  Future<String?> getToken();

  /// New tokens issued by the platform.
  Stream<String> get onTokenRefresh;

  /// The current notification permission.
  Future<DevicePermission> getPermission();

  /// Asks the user for permission.
  Future<DevicePermission> requestPermission({required bool provisional});

  /// Creates Android channels; a no-op elsewhere.
  Future<void> createAndroidChannels(List<RelayAndroidChannel> channels);

  /// The Android channels as the system reports them now.
  Future<List<AndroidChannel>> getAndroidChannels();

  /// Interruption permissions.
  Future<RelayInterruptionCapabilities> getInterruptionCapabilities();

  /// Shows a notification.
  Future<void> show(RelayLocalNotification notification);

  /// The tags of the notifications currently shown.
  Future<List<String>> shownTags();

  /// Removes shown notifications by tag.
  Future<void> remove(List<String> tags);
}

/// Content of a content-free push fetched by the app.
class RelayPushContent {
  /// Creates content.
  const RelayPushContent({
    required this.title,
    required this.body,
    this.url,
    this.notificationId,
  });

  /// The title.
  final String title;

  /// The body.
  final String body;

  /// The target link.
  final String? url;

  /// The notification identifier, when known.
  final String? notificationId;
}

// CH-33
/// Fetches the content of a content-free push over TLS.
abstract interface class RelayPushContentSource {
  /// The content of a delivery, or null when it cannot be fetched.
  Future<RelayPushContent?> fetch(String deliveryId);
}

/// The default source: Relay has no client fetch endpoint yet, so the generic text is shown.
class NoRelayPushContentSource implements RelayPushContentSource {
  /// Creates the source.
  const NoRelayPushContentSource();

  @override
  Future<RelayPushContent?> fetch(String deliveryId) async => null;
}
