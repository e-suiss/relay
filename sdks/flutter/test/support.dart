import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:esuiss_relay/esuiss_relay.dart';
import 'package:http/http.dart' as hc;
import 'package:http/testing.dart';

final Uri base = Uri.parse('https://relay.test');

Map<String, Object?> vector(String name) =>
    jsonDecode(File('../../conformance/sdk/mobile/$name').readAsStringSync())
        as Map<String, Object?>;

class FakeRandom implements RelayRandom {
  FakeRandom([this.value = 0.5]);

  double value;
  int _n = 0;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => (_n++ * 7 + 3) % max;
}

class FakeClock implements RelayClock {
  FakeClock([DateTime? start]) : time = start ?? DateTime.utc(2026, 11, 18, 9);

  DateTime time;

  @override
  DateTime now() => time;
}

class RecordingLogger implements RelayLogger {
  final List<(String, Map<String, Object?>)> events =
      <(String, Map<String, Object?>)>[];

  @override
  void log(
    RelayLogLevel level,
    String event, [
    Map<String, Object?> fields = const <String, Object?>{},
  ]) {
    events.add((event, fields));
  }
}

class Delays {
  final List<Duration> waits = <Duration>[];

  Future<void> call(Duration d) async {
    waits.add(d);
  }
}

class TokenSource {
  int calls = 0;
  int forced = 0;

  Future<SubscriberToken> call({required bool forceRefresh}) async {
    calls++;
    if (forceRefresh) forced++;
    return SubscriberToken('token-$calls');
  }
}

typedef Handler = FutureOr<hc.Response> Function(hc.Request request);

class Server {
  Server(this.handler);

  Handler handler;
  final List<hc.Request> requests = <hc.Request>[];

  MockClient get client => MockClient((hc.Request r) async {
    requests.add(r);
    return handler(r);
  });

  List<String> get calls => <String>[
    for (final hc.Request r in requests) '${r.method} ${r.url.path}',
  ];
}

hc.Response json(
  Object? body, {
  int status = 200,
  Map<String, String> headers = const <String, String>{},
}) => hc.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json', ...headers},
);

hc.Response problem(
  int status,
  String code, {
  bool retryable = false,
  Map<String, String> headers = const <String, String>{},
  Map<String, Object?> extra = const <String, Object?>{},
}) => json(
  <String, Object?>{
    'type': 'https://relay.test/v1/errors/$code',
    'title': code,
    'status': status,
    'code': code,
    'retryable': retryable,
    ...extra,
  },
  status: status,
  headers: headers,
);

RelayHttp httpCore(
  Server server, {
  TokenSource? tokens,
  Delays? delays,
  RelayLogger? logger,
}) => RelayHttp(
  baseUrl: base,
  tokenProvider: (tokens ?? TokenSource()).call,
  client: server.client,
  random: FakeRandom(),
  delay: (delays ?? Delays()).call,
  logger: logger,
);

const String ts = '2026-11-18T09:00:00Z';

Map<String, Object?> counters({
  int unseen = 0,
  int unread = 0,
  int total = 0,
  int version = 1,
}) => <String, Object?>{
  'object': 'inbox_counters',
  'unseen': unseen,
  'unread': unread,
  'total': total,
  'version': version,
};

Map<String, Object?> state(
  String id, {
  int version = 1,
  bool read = false,
  bool hidden = false,
  bool archived = false,
}) => <String, Object?>{
  'id': id,
  'state_version': version,
  'seen': read,
  'read': read,
  'archived': archived,
  'hidden': hidden,
  'expired': false,
  'snoozed_until': null,
  'seen_at': null,
  'read_at': read ? ts : null,
  'archived_at': null,
};

Map<String, Object?> item(
  String id, {
  int version = 1,
  bool read = false,
  String title = 'Title',
  String activity = ts,
  String? senderType,
  bool? approval,
  Map<String, Object?>? waitpoint,
  List<Object?> actions = const <Object?>[],
}) => <String, Object?>{
  'object': 'inbox_item',
  ...state(id, version: version, read: read),
  'created_at': ts,
  'last_activity_at': activity,
  'category': 'orders',
  'tags': <Object?>[],
  'severity': null,
  'group_key': null,
  'title': title,
  'body': 'Body of $id',
  'avatar_url': null,
  'url': null,
  'actions': actions,
  'data': <Object?>[],
  'locale': 'en',
  'dir': null,
  'activity_count': 1,
  'actor_count': 0,
  'expires_at': null,
  if (senderType != null) 'sender_type': senderType,
  if (approval != null) 'approval': approval,
  'waitpoint': waitpoint,
};

const String wp1 = 'wp_01j9zq3k4m5n6p7q8r9s0t1v2w';
const String digest1 =
    '0000000000000000000000000000000000000000000000000000000000000001';

Map<String, Object?> waitpoint({
  String kind = 'response',
  String status = 'awaiting',
  String? subjectDigest = digest1,
  List<Object?> options = const <Object?>[
    <String, Object?>{'label': 'Evet', 'value': 'yes'},
    <String, Object?>{'label': 'Hayır', 'value': 'no'},
  ],
  Map<String, Object?>? responder,
  String? respondedAt,
  String? approvalUrl,
}) => <String, Object?>{
  'id': wp1,
  'kind': kind,
  'status': status,
  'subject_digest': subjectDigest,
  'options': options,
  'responder': responder,
  'responded_at': respondedAt,
  'approval_url': approvalUrl,
};

Map<String, Object?> envelope(
  String t,
  Map<String, Object?> d, {
  String id = 'c1',
  int version = 1,
}) => <String, Object?>{
  't': t,
  'v': 1,
  'ts': ts,
  'id': id,
  'd': d,
  'counters': <String, Object?>{
    'unseen': 0,
    'unread': 0,
    'total': 0,
    'version': version,
  },
};

const String inb1 = 'inb_01j9zq3k4m5n6p7q8r9s0t1v2w';
const String inb2 = 'inb_01j9zq3k4m5n6p7q8r9s0t1v2x';
const String dev1 = 'dev_01j9zq3k4m5n6p7q8r9s0t1v2w';
const String dlv1 = 'dlv_01j9zq3k4m5n6p7q8r9s0t1v2w';
const String ntf1 = 'ntf_01j9zq3k4m5n6p7q8r9s0t1v2w';
const String sub1 = 'sub_01j9zq3k4m5n6p7q8r9s0t1v2w';

Map<String, Object?> device({
  String permission = 'granted',
  String platform = 'fcm',
}) => <String, Object?>{
  'object': 'device',
  'id': dev1,
  'subscriber_id': sub1,
  'platform': platform,
  'app': 'com.example.app',
  'token_fingerprint': 'aaaabbbbccccdddd',
  'apns_environment': null,
  'permission': permission,
  'android_channels': <Object?>[],
  'locale': null,
  'state': 'active',
  'disabled_reason': null,
  'registered_at': ts,
  'last_seen_at': ts,
  'deleted_at': null,
  'created_at': ts,
  'updated_at': ts,
};

class FakePushAdapter implements RelayPushAdapter {
  FakePushAdapter({
    this.platform = DevicePlatform.fcm,
    this.token = 'push-token-1',
  });

  @override
  final DevicePlatform platform;

  String? token;
  DevicePermission permission = DevicePermission.granted;
  final List<RelayAndroidChannel> created = <RelayAndroidChannel>[];
  final List<RelayLocalNotification> shown = <RelayLocalNotification>[];
  final List<String> removed = <String>[];
  bool? lastProvisional;
  final StreamController<String> refresh = StreamController<String>.broadcast();

  @override
  String get appId => 'com.example.app';

  @override
  ApnsEnvironment? get apnsEnvironment => ApnsEnvironment.sandbox;

  @override
  Future<String?> getToken() async => token;

  @override
  Stream<String> get onTokenRefresh => refresh.stream;

  @override
  Future<DevicePermission> getPermission() async => permission;

  @override
  Future<DevicePermission> requestPermission({
    required bool provisional,
  }) async {
    lastProvisional = provisional;
    permission = provisional
        ? DevicePermission.provisional
        : DevicePermission.granted;
    return permission;
  }

  @override
  Future<void> createAndroidChannels(List<RelayAndroidChannel> channels) async {
    created.addAll(channels);
  }

  @override
  Future<List<AndroidChannel>> getAndroidChannels() async => <AndroidChannel>[
    for (final RelayAndroidChannel c in created)
      AndroidChannel(id: c.id, importance: c.importance),
  ];

  RelayInterruptionCapabilities interruption =
      const RelayInterruptionCapabilities(
        dndAccess: DeviceInterruptionPermission.denied,
      );
  bool interruptionFails = false;

  @override
  Future<RelayInterruptionCapabilities> getInterruptionCapabilities() async {
    if (interruptionFails) throw StateError('unavailable');
    return interruption;
  }

  @override
  Future<void> show(RelayLocalNotification notification) async {
    shown.add(notification);
  }

  @override
  Future<List<String>> shownTags() async => <String>[
    for (final RelayLocalNotification n in shown)
      if (!removed.contains(n.tag)) n.tag,
  ];

  @override
  Future<void> remove(List<String> tags) async {
    removed.addAll(tags);
  }
}
