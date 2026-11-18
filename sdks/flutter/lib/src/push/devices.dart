import 'dart:async';
import 'dart:convert';

import '../core/errors.dart';
import '../core/http.dart';
import '../core/ports.dart';
import '../generated/models.dart';
import '../generated/operations.dart';
import 'adapter.dart';
import 'channels.dart';

// CH-28
// CH-30
// CH-31
// CH-65
/// Registers the push token on every start, reports the permission, the Android channels and the interruption permissions, and follows token refreshes.
class RelayDeviceRegistrar {
  /// Creates the registrar.
  RelayDeviceRegistrar({
    required this.http,
    required this.adapter,
    required this.store,
    this.categories = const <RelayCategory>[],
    this.locale,
    this.timezone,
    RelayLogger? logger,
  }) : logger = logger ?? const SilentRelayLogger();

  /// The HTTP core.
  final RelayHttp http;

  /// The platform push bridge.
  final RelayPushAdapter adapter;

  /// Durable storage for the device id and the last token.
  final RelayKeyValueStore store;

  /// The categories whose Android channels the SDK creates.
  final List<RelayCategory> categories;

  /// The device locale.
  final String? locale;

  /// The device IANA time zone.
  final String? timezone;

  /// The logger; it never receives the token.
  final RelayLogger logger;

  static const String _deviceKey = 'relay.device.id';
  static const String _tokenKey = 'relay.device.token';
  static const String _reportKey = 'relay.device.report';

  StreamSubscription<String>? _refresh;
  DevicePermission? _permission;

  /// The permission reported last.
  DevicePermission? get permission => _permission;

  /// The registered device id.
  Future<String?> deviceId() => store.read(_deviceKey);

  bool get _android =>
      adapter.platform == DevicePlatform.fcm ||
      adapter.platform == DevicePlatform.hms;

  /// Creates the Android channels, registers the token and starts following refreshes.
  Future<Device?> start() async {
    if (_android) {
      await adapter.createAndroidChannels(relayAndroidChannels(categories));
    }
    _refresh ??= adapter.onTokenRefresh.listen((String token) {
      unawaited(_register(token).catchError((Object _) => null));
    });
    final String? token = await adapter.getToken();
    if (token == null) return null;
    return _register(token);
  }

  /// Registers again when the permission or the channels changed since the last report.
  Future<Device?> refreshIfChanged() async {
    final String? token = await adapter.getToken();
    if (token == null) return null;
    final String report = await _report();
    if (report == await store.read(_reportKey) &&
        token == await store.read(_tokenKey)) {
      return null;
    }
    return _register(token);
  }

  Future<String> _report() async {
    final DevicePermission permission = await adapter.getPermission();
    final List<AndroidChannel> channels = _android
        ? await adapter.getAndroidChannels()
        : <AndroidChannel>[];
    final DeviceInterruptionPermissions? interruption = await _interruption();
    return jsonEncode(<String, Object?>{
      'permission': permission.wire,
      'channels': <Object?>[
        for (final AndroidChannel c in channels) c.toJson(),
      ],
      'interruption': interruption?.toJson(),
    });
  }

  // CH-65
  Future<DeviceInterruptionPermissions?> _interruption() async {
    try {
      return relayInterruptionPermissions(
        adapter.platform,
        await adapter.getInterruptionCapabilities(),
      );
    } on Object {
      return null;
    }
  }

  Future<Device?> _register(String token) async {
    final DevicePermission permission = await adapter.getPermission();
    _permission = permission;
    final List<AndroidChannel>? channels = _android
        ? await adapter.getAndroidChannels()
        : null;
    final DeviceInterruptionPermissions? interruption = await _interruption();
    final String? previous = await store.read(_tokenKey);
    final DeviceRegistration registration = DeviceRegistration(
      platform: adapter.platform,
      token: token,
      app: adapter.appId,
      apnsEnvironment: adapter.platform == DevicePlatform.apns
          ? adapter.apnsEnvironment
          : null,
      permission: permission,
      androidChannels: channels,
      locale: locale,
      timezone: timezone,
      interruptionPermissions: interruption,
      previousToken: previous != null && previous != token ? previous : null,
    );
    final RelayResponse response = await http.send(
      RelayOperation.registerMyDevice,
      body: registration.toJson(),
    );
    final Device device = Device.fromJson(response.json);
    await store.write(_deviceKey, device.id);
    await store.write(_tokenKey, token);
    await store.write(_reportKey, await _report());
    logger.log(RelayLogLevel.info, 'device.registered', <String, Object?>{
      'device_id': device.id,
      'fingerprint': device.tokenFingerprint,
    });
    return device;
  }

  /// Asks for permission: provisional only when every starting class is marketing or social (CH-29).
  Future<DevicePermission> requestPermission(
    Iterable<RelayMessageClass> classes,
  ) async {
    final DevicePermission result = await adapter.requestPermission(
      provisional: relayUseProvisional(classes),
    );
    await refreshIfChanged();
    return result;
  }

  /// Disables this device on sign-out; the row and the preferences stay.
  Future<void> unregister() async {
    final String? id = await store.read(_deviceKey);
    await _refresh?.cancel();
    _refresh = null;
    if (id != null) {
      try {
        await http.send(
          RelayOperation.deleteMyDevice,
          pathParams: <String, String>{'device_id': id},
        );
      } on RelayNotFoundError {
        logger.log(RelayLogLevel.debug, 'device.already_removed');
      }
    }
    await store.remove(_deviceKey);
    await store.remove(_tokenKey);
    await store.remove(_reportKey);
  }

  /// Stops following token refreshes.
  Future<void> dispose() async {
    await _refresh?.cancel();
    _refresh = null;
  }
}
