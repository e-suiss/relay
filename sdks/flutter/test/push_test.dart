import 'dart:convert';

import 'package:esuiss_relay/esuiss_relay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as hc;

import 'support.dart';

Map<String, Object?> body(hc.Request r) =>
    jsonDecode(r.body) as Map<String, Object?>;

void main() {
  group('CH-28 CH-31 device registration', () {
    test('CH-28 registers the token with the permission and the stable Android channels on start', () async {
      final Server server = Server(
        (hc.Request r) => json(device(), status: 201),
      );
      final FakePushAdapter adapter = FakePushAdapter();
      final RecordingLogger logger = RecordingLogger();
      final RelayDeviceRegistrar registrar = RelayDeviceRegistrar(
        http: httpCore(server),
        adapter: adapter,
        store: MemoryRelayKeyValueStore(),
        categories: const <RelayCategory>[
          RelayCategory('orders', RelayMessageClass.transactional),
        ],
        locale: 'tr-TR',
        timezone: 'Europe/Istanbul',
        logger: logger,
      );
      final Device? d = await registrar.start();
      expect(d?.id, dev1);
      expect(server.calls, <String>['POST /v1/subscriber/devices']);
      final Map<String, Object?> sent = body(server.requests.single);
      expect(sent['platform'], 'fcm');
      expect(sent['token'], 'push-token-1');
      expect(sent['permission'], 'granted');
      expect(sent['locale'], 'tr-TR');
      expect(sent['timezone'], 'Europe/Istanbul');
      expect(sent.containsKey('apns_environment'), isFalse);
      expect(sent.containsKey('previous_token'), isFalse);
      expect(
        (sent['android_channels']! as List<Object?>).map(
          (Object? c) => (c! as Map<String, Object?>)['id'],
        ),
        <String>[
          'relay.orders.passive',
          'relay.orders.active',
          'relay.orders.time-sensitive',
        ],
      );
      expect(server.requests.single.headers['Idempotency-Key'], isNotNull);
      expect(
        jsonEncode(logger.events.map((e) => e.$2).toList()),
        isNot(contains('push-token-1')),
      );
      await registrar.dispose();
    });

    test('CH-31 a refreshed token is registered with previous_token', () async {
      final Server server = Server((hc.Request r) => json(device()));
      final FakePushAdapter adapter = FakePushAdapter();
      final MemoryRelayKeyValueStore store = MemoryRelayKeyValueStore();
      final RelayDeviceRegistrar registrar = RelayDeviceRegistrar(
        http: httpCore(server),
        adapter: adapter,
        store: store,
      );
      await registrar.start();
      adapter.token = 'push-token-2';
      await registrar.refreshIfChanged();
      final Map<String, Object?> second = body(server.requests.last);
      expect(second['token'], 'push-token-2');
      expect(second['previous_token'], 'push-token-1');
      await registrar.dispose();
    });

    test('CH-28 reports again only when the permission changed', () async {
      final Server server = Server((hc.Request r) => json(device()));
      final FakePushAdapter adapter = FakePushAdapter();
      final RelayDeviceRegistrar registrar = RelayDeviceRegistrar(
        http: httpCore(server),
        adapter: adapter,
        store: MemoryRelayKeyValueStore(),
      );
      await registrar.start();
      await registrar.refreshIfChanged();
      expect(server.requests, hasLength(1));
      adapter.permission = DevicePermission.denied;
      await registrar.refreshIfChanged();
      expect(server.requests, hasLength(2));
      expect(body(server.requests.last)['permission'], 'denied');
      await registrar.dispose();
    });

    test(
      'CH-29 asks for provisional authorisation only for marketing and social',
      () async {
        final Server server = Server((hc.Request r) => json(device()));
        final FakePushAdapter adapter = FakePushAdapter(
          platform: DevicePlatform.apns,
        );
        final RelayDeviceRegistrar registrar = RelayDeviceRegistrar(
          http: httpCore(server),
          adapter: adapter,
          store: MemoryRelayKeyValueStore(),
        );
        await registrar.requestPermission(<RelayMessageClass>[
          RelayMessageClass.marketing,
        ]);
        expect(adapter.lastProvisional, isTrue);
        await registrar.requestPermission(<RelayMessageClass>[
          RelayMessageClass.security,
        ]);
        expect(adapter.lastProvisional, isFalse);
        expect(body(server.requests.first)['apns_environment'], 'sandbox');
        await registrar.dispose();
      },
    );

    test(
      'CH-65 an Android device reports Do Not Disturb access only',
      () async {
        final Server server = Server((hc.Request r) => json(device()));
        final FakePushAdapter adapter = FakePushAdapter()
          ..interruption = const RelayInterruptionCapabilities(
            dndAccess: DeviceInterruptionPermission.granted,
            criticalAlerts: DeviceInterruptionPermission.granted,
          );
        final RelayDeviceRegistrar registrar = RelayDeviceRegistrar(
          http: httpCore(server),
          adapter: adapter,
          store: MemoryRelayKeyValueStore(),
        );
        await registrar.start();
        expect(
          body(server.requests.single)['interruption_permissions'],
          <String, Object?>{'dnd_access': 'granted'},
        );
        await registrar.dispose();
      },
    );

    test(
      'CH-65 an iOS device reports critical alerts and time-sensitive only',
      () async {
        final Server server = Server(
          (hc.Request r) => json(device(platform: 'apns')),
        );
        final FakePushAdapter adapter =
            FakePushAdapter(platform: DevicePlatform.apns)
              ..interruption = const RelayInterruptionCapabilities(
                criticalAlerts: DeviceInterruptionPermission.denied,
                timeSensitive: DeviceInterruptionPermission.notDetermined,
                dndAccess: DeviceInterruptionPermission.granted,
              );
        final RelayDeviceRegistrar registrar = RelayDeviceRegistrar(
          http: httpCore(server),
          adapter: adapter,
          store: MemoryRelayKeyValueStore(),
        );
        await registrar.start();
        expect(
          body(server.requests.single)['interruption_permissions'],
          <String, Object?>{
            'critical_alerts': 'denied',
            'time_sensitive': 'not_determined',
          },
        );
        await registrar.dispose();
      },
    );

    test('CH-65 nothing is reported when the permissions are unknown or cannot be read', () async {
      final Server server = Server((hc.Request r) => json(device()));
      final FakePushAdapter adapter = FakePushAdapter()
        ..interruption = const RelayInterruptionCapabilities();
      final RelayDeviceRegistrar registrar = RelayDeviceRegistrar(
        http: httpCore(server),
        adapter: adapter,
        store: MemoryRelayKeyValueStore(),
      );
      await registrar.start();
      expect(
        body(server.requests.last).containsKey('interruption_permissions'),
        isFalse,
      );
      adapter.interruptionFails = true;
      adapter.token = 'push-token-2';
      await registrar.refreshIfChanged();
      expect(server.requests, hasLength(2));
      expect(
        body(server.requests.last).containsKey('interruption_permissions'),
        isFalse,
      );
      await registrar.dispose();
    });

    test('CH-65 a changed interruption permission is reported again', () async {
      final Server server = Server((hc.Request r) => json(device()));
      final FakePushAdapter adapter = FakePushAdapter();
      final RelayDeviceRegistrar registrar = RelayDeviceRegistrar(
        http: httpCore(server),
        adapter: adapter,
        store: MemoryRelayKeyValueStore(),
      );
      await registrar.start();
      await registrar.refreshIfChanged();
      expect(server.requests, hasLength(1));
      adapter.interruption = const RelayInterruptionCapabilities(
        dndAccess: DeviceInterruptionPermission.granted,
      );
      await registrar.refreshIfChanged();
      expect(server.requests, hasLength(2));
      expect(
        body(server.requests.last)['interruption_permissions'],
        <String, Object?>{'dnd_access': 'granted'},
      );
      await registrar.dispose();
    });

    test('CH-31 sign-out disables the device', () async {
      final Server server = Server((hc.Request r) => json(device()));
      final MemoryRelayKeyValueStore store = MemoryRelayKeyValueStore();
      final RelayDeviceRegistrar registrar = RelayDeviceRegistrar(
        http: httpCore(server),
        adapter: FakePushAdapter(),
        store: store,
      );
      await registrar.start();
      await registrar.unregister();
      expect(server.calls.last, 'DELETE /v1/subscriber/devices/$dev1');
      expect(await registrar.deviceId(), isNull);
    });
  });

  group('CH-32 receipts', () {
    test('CH-32 a receipt made offline is sent later with the same Idempotency-Key', () async {
      bool online = false;
      final Server server = Server((hc.Request r) {
        if (!online) throw hc.ClientException('offline');
        return json(<String, Object?>{
          'object': 'push_receipt',
          'delivery_id': dlv1,
          'receipt': 'displayed',
        }, status: 202);
      });
      final MemoryRelayKeyValueStore store = MemoryRelayKeyValueStore();
      final RelayReceiptQueue queue = RelayReceiptQueue(
        http: httpCore(server),
        store: store,
        clock: FakeClock(),
      );
      await queue.add(dlv1, RelayReceipt.displayed);
      expect(await queue.pending, 1);
      online = true;
      await queue.flush();
      expect(await queue.pending, 0);
      expect(
        server.requests.first.headers['Idempotency-Key'],
        server.requests.last.headers['Idempotency-Key'],
      );
      expect(body(server.requests.last), <String, Object?>{
        'delivery_id': dlv1,
        'receipt': 'displayed',
        'occurred_at': '2026-11-18T09:00:00.000Z',
      });
    });

    test('CH-32 a receipt for an unknown delivery is dropped', () async {
      final Server server = Server(
        (hc.Request r) => problem(404, 'delivery_not_found'),
      );
      final RelayReceiptQueue queue = RelayReceiptQueue(
        http: httpCore(server),
        store: MemoryRelayKeyValueStore(),
      );
      await queue.add(dlv1, RelayReceipt.clicked);
      expect(await queue.pending, 0);
    });
  });

  group('IN-47 IN-48 device status', () {
    test('IN-53 sends only changed signals, at most once a second, without an Idempotency-Key and without logging values', () async {
      final Server server = Server(
        (hc.Request r) => json(<String, Object?>{
          'object': 'device_status',
          'device_id': dev1,
          'version': 'v1',
          'signals': <String, Object?>{
            'worn': 'unknown',
            'locked': true,
            'headphones': 'unknown',
            'focus': 'unknown',
            'break': 'unknown',
          },
        }),
      );
      final RecordingLogger logger = RecordingLogger();
      final FakeClock clock = FakeClock();
      final Delays delays = Delays();
      final RelayDeviceStatusWriter writer = RelayDeviceStatusWriter(
        http: httpCore(server, logger: logger),
        deviceId: () async => dev1,
        clock: clock,
        delay: delays.call,
        logger: logger,
      );
      await writer.set(<RelayDeviceSignal, bool>{
        RelayDeviceSignal.locked: true,
        RelayDeviceSignal.breakPoint: false,
      });
      await writer.set(<RelayDeviceSignal, bool>{
        RelayDeviceSignal.locked: true,
        RelayDeviceSignal.focus: true,
      }, ttl: const Duration(hours: 1));
      expect(server.calls, <String>[
        'PATCH /v1/subscriber/devices/$dev1/status',
        'PATCH /v1/subscriber/devices/$dev1/status',
      ]);
      expect(body(server.requests[0]), <String, Object?>{
        'version': 'v1',
        'signals': <String, Object?>{'locked': true, 'break': false},
        'ttl': 'PT300S',
      });
      expect(body(server.requests[1]), <String, Object?>{
        'version': 'v1',
        'signals': <String, Object?>{'focus': true},
        'ttl': 'PT900S',
      });
      expect(delays.waits, <Duration>[const Duration(seconds: 1)]);
      for (final hc.Request r in server.requests) {
        expect(r.headers.containsKey('Idempotency-Key'), isFalse);
      }
      for (final (String, Map<String, Object?>) e in logger.events) {
        expect(e.$2.values.whereType<bool>(), isEmpty);
        expect(jsonEncode(e.$2), isNot(contains('locked')));
      }
    });

    test('IN-53 clamps the time to live to PT1S … PT15M', () {
      expect(
        RelayDeviceStatusWriter.clampTtl(null),
        const Duration(minutes: 5),
      );
      expect(
        RelayDeviceStatusWriter.clampTtl(Duration.zero),
        const Duration(seconds: 1),
      );
      expect(
        RelayDeviceStatusWriter.clampTtl(const Duration(days: 1)),
        const Duration(minutes: 15),
      );
    });
  });

  group('CH-33 IN-38 push handling', () {
    RelayPushHandler handler(
      FakePushAdapter adapter,
      Server server, {
      RelayPushContentSource source = const NoRelayPushContentSource(),
      int unread = 0,
      MemoryRelayKeyValueStore? store,
    }) {
      final MemoryRelayKeyValueStore s = store ?? MemoryRelayKeyValueStore();
      return RelayPushHandler(
        adapter: adapter,
        receipts: RelayReceiptQueue(http: httpCore(server), store: s),
        store: s,
        contentSource: source,
        locale: 'tr-TR',
        onSync: (int? _) async => InboxCounters(
          object: 'inbox_counters',
          unseen: 0,
          unread: unread,
          total: 1,
          version: 9,
        ),
      );
    }

    Server receiptServer() => Server(
      (hc.Request r) => json(<String, Object?>{
        'object': 'push_receipt',
        'delivery_id': dlv1,
        'receipt': 'displayed',
      }, status: 202),
    );

    test('CH-33 a content-free push without fetchable content shows the generic text and never its content', () async {
      final FakePushAdapter adapter = FakePushAdapter();
      final Server server = receiptServer();
      await handler(adapter, server).handle(<String, Object?>{
        'data': <String, Object?>{'relay_id': dlv1},
      });
      expect(adapter.shown.single.title, 'Yeni bildirim');
      expect(adapter.shown.single.body, 'Yeni bir bildiriminiz var.');
      expect(adapter.shown.single.tag, dlv1);
      expect(body(server.requests.single)['receipt'], 'displayed');
    });

    test(
      'CH-33 fetched content is shown and indexes the notification for removal',
      () async {
        final FakePushAdapter adapter = FakePushAdapter();
        final MemoryRelayKeyValueStore store = MemoryRelayKeyValueStore();
        final RelayPushHandler h = handler(
          adapter,
          receiptServer(),
          source: _Source(),
          store: store,
        );
        await h.handle(<String, Object?>{
          'data': <String, Object?>{
            'relay_id': dlv1,
            'relay_neutral_title': 'x',
            'relay_neutral_body': 'y',
          },
        });
        expect(adapter.shown.single.title, 'Order shipped');
        await h.handle(<String, Object?>{
          'data': <String, Object?>{
            'relay_sync': '1',
            'relay_counter_version': '5',
            'relay_read': ntf1,
          },
        });
        expect(adapter.removed, <String>[dlv1]);
      },
    );

    test('IN-38 a sync that leaves nothing unread removes the shown Relay notifications', () async {
      final FakePushAdapter adapter = FakePushAdapter();
      final RelayPushHandler h = handler(adapter, receiptServer());
      await h.handle(<String, Object?>{
        'data': <String, Object?>{'relay_id': dlv1},
      });
      await h.handle(<String, Object?>{
        'data': <String, Object?>{'relay_sync': '1'},
      });
      expect(adapter.removed, <String>[dlv1]);
    });

    Map<String, Object?> pushContent(Map<String, Object?> content) =>
        <String, Object?>{
          'object': 'push_content',
          'delivery_id': dlv1,
          'notification_id': ntf1,
          'channel': 'push',
          'locale': 'tr',
          'content': content,
        };

    RelayPushHandler apiHandler(FakePushAdapter adapter, Server server) {
      final MemoryRelayKeyValueStore s = MemoryRelayKeyValueStore();
      return RelayPushHandler(
        adapter: adapter,
        receipts: RelayReceiptQueue(http: httpCore(server), store: s),
        store: s,
        locale: 'tr-TR',
        onSync: (int? _) async => null,
      );
    }

    test(
      'CH-33 by default the content is fetched from Relay by the delivery id',
      () async {
        final FakePushAdapter adapter = FakePushAdapter();
        final Server server = Server((hc.Request r) {
          if (r.method == 'GET') {
            return json(
              pushContent(<String, Object?>{
                'title': 'Siparişiniz yolda',
                'body': 'Yarın teslim',
                'url': 'https://shop.example/orders/1',
              }),
            );
          }
          return json(<String, Object?>{
            'object': 'push_receipt',
            'delivery_id': dlv1,
            'receipt': 'displayed',
          }, status: 202);
        });
        await apiHandler(adapter, server).handle(<String, Object?>{
          'data': <String, Object?>{'relay_id': dlv1},
        });
        expect(server.calls.first, 'GET /v1/subscriber/push_content/$dlv1');
        expect(adapter.shown.single.title, 'Siparişiniz yolda');
        expect(adapter.shown.single.body, 'Yarın teslim');
        expect(adapter.shown.single.url, 'https://shop.example/orders/1');
      },
    );

    test('CH-33 a failed fetch shows the generic text and never content from the payload', () async {
      final FakePushAdapter adapter = FakePushAdapter();
      final Server server = Server((hc.Request r) {
        if (r.method == 'GET') return problem(404, 'delivery_not_found');
        return json(<String, Object?>{
          'object': 'push_receipt',
          'delivery_id': dlv1,
          'receipt': 'displayed',
        }, status: 202);
      });
      await apiHandler(adapter, server).handle(<String, Object?>{
        'data': <String, Object?>{'relay_id': dlv1, 'relay_url': 'https://x'},
      });
      expect(server.calls.first, 'GET /v1/subscriber/push_content/$dlv1');
      expect(adapter.shown.single.title, 'Yeni bildirim');
      expect(adapter.shown.single.body, 'Yeni bir bildiriminiz var.');
      expect(adapter.shown.single.url, isNull);
    });

    test('CH-33 content without a title or body counts as not fetched', () {
      expect(
        relayPushContentOf(
          PushContent.fromJson(pushContent(<String, Object?>{'url': 'x'})),
        ),
        isNull,
      );
      final RelayPushContent? c = relayPushContentOf(
        PushContent.fromJson(pushContent(<String, Object?>{'body': 'B'})),
      );
      expect(c?.title, '');
      expect(c?.body, 'B');
      expect(c?.notificationId, ntf1);
    });

    test('CH-32 a click is recorded as a clicked receipt', () async {
      final Server server = receiptServer();
      await handler(FakePushAdapter(), server).clicked(dlv1);
      expect(body(server.requests.single)['receipt'], 'clicked');
    });
  });
}

class _Source implements RelayPushContentSource {
  @override
  Future<RelayPushContent?> fetch(String deliveryId) async =>
      const RelayPushContent(
        title: 'Order shipped',
        body: 'Arrives tomorrow',
        notificationId: ntf1,
      );
}
