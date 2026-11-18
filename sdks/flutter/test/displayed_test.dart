import 'dart:async';

import 'package:esuiss_relay/esuiss_relay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as hc;

import 'support.dart';

const String ntfDigest =
    '01e1f56f89cc1450b1bf7132af0a61ecd8f650d8f5e346b207d49f00a9796537';

const String path = '/v1/subscriber/displayed_notifications';

RelayDisplayedNotifications reporter(
  Server server, {
  bool enabled = true,
  FakeClock? clock,
  Ticks? ticks,
}) => RelayDisplayedNotifications(
  http: httpCore(server),
  enabled: enabled,
  clock: clock ?? FakeClock(),
  periodic: (ticks ?? Ticks()).call,
);

List<int> sizes(Server server) => <int>[
  for (final hc.Request r in server.requests)
    displayedNotifications(r).length,
];

void main() {
  group('OP-95 displayed notification digests', () {
    test('OP-95 the digest is the SHA-256 of the identifier', () {
      expect(
        relayDisplayedDigest(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        relayDisplayedDigest('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        relayDisplayedDigest(
          'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
      expect(
        relayDisplayedDigest('a' * 1000),
        '41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3',
      );
      expect(
        relayDisplayedDigest('ğüşİ bildirim'),
        '9c52c38bc9c42e2781313a70ca26cac54d0eb7b9adb8b27fcf6b2bd1e11a72ab',
      );
      expect(relayDisplayedDigest(ntf1), ntfDigest);
    });

    test('OP-95 nothing is queued or sent while disabled', () async {
      final Server server = Server((hc.Request r) => displayedAccepted());
      final Ticks ticks = Ticks();
      final RelayDisplayedNotifications d = reporter(
        server,
        enabled: false,
        ticks: ticks,
      );
      for (int i = 0; i < 25; i++) {
        await d.report(ntf1);
      }
      await d.flush();
      expect(d.pending, 0);
      expect(ticks.intervals, isEmpty);
      expect(server.requests, isEmpty);
    });

    test('OP-95 twenty displays send one batch, repeats included', () async {
      final Server server = Server((hc.Request r) => displayedAccepted());
      final RelayDisplayedNotifications d = reporter(server);
      for (int i = 0; i < 19; i++) {
        await d.report(ntf1);
      }
      expect(server.requests, isEmpty);
      await d.report(ntf1);
      expect(server.calls, <String>['POST $path']);
      final hc.Request request = server.requests.single;
      expect(request.headers['Idempotency-Key'], isNotNull);
      expect(request.headers['Authorization'], startsWith('Bearer '));
      final List<Map<String, Object?>> sent = displayedNotifications(request);
      expect(sent, hasLength(20));
      expect(sent.first, <String, Object?>{
        'digest': ntfDigest,
        'displayed_at': '2026-11-18T09:00:00.000Z',
      });
      expect(request.body, isNot(contains(ntf1)));
      expect(d.pending, 0);
    });

    test('OP-95 the 30 second tick sends what is queued', () async {
      final Server server = Server((hc.Request r) => displayedAccepted());
      final Ticks ticks = Ticks();
      final RelayDisplayedNotifications d = reporter(server, ticks: ticks);
      await d.report(ntf1);
      await d.report(ntf1);
      expect(ticks.intervals, <Duration>[const Duration(seconds: 30)]);
      expect(server.requests, isEmpty);
      ticks.ticks.single.call();
      await d.flush();
      expect(sizes(server), <int>[2]);
      d.dispose();
      expect(ticks.stopped, 1);
    });

    test('OP-95 one request carries at most 100 notifications', () async {
      final Completer<void> gate = Completer<void>();
      final Server server = Server((hc.Request r) async {
        await gate.future;
        return displayedAccepted();
      });
      final RelayDisplayedNotifications d = reporter(server);
      for (int i = 0; i < 150; i++) {
        unawaited(d.report(ntf1));
      }
      gate.complete();
      await d.flush();
      await d.flush();
      expect(sizes(server), <int>[20, 100, 30]);
      expect(d.pending, 0);
    });

    test('OP-95 a failed batch is resent with the same key', () async {
      int n = 0;
      final Server server = Server((hc.Request r) {
        n++;
        if (n == 1) {
          return problem(503, 'service_unavailable', retryable: true);
        }
        return displayedAccepted();
      });
      final RelayDisplayedNotifications d = reporter(server);
      await d.report(ntf1);
      await d.flush();
      expect(server.requests, hasLength(1));
      expect(d.pending, 1);
      await d.flush();
      expect(server.requests, hasLength(2));
      expect(
        server.requests[0].headers['Idempotency-Key'],
        server.requests[1].headers['Idempotency-Key'],
      );
      expect(d.pending, 0);
    });

    test('OP-95 a batch older than a day is dropped', () async {
      final Server server = Server(
        (hc.Request r) => problem(503, 'service_unavailable', retryable: true),
      );
      final FakeClock clock = FakeClock();
      final RelayDisplayedNotifications d = reporter(server, clock: clock);
      await d.report(ntf1);
      await d.flush();
      expect(d.pending, 1);
      clock.time = clock.time.add(const Duration(hours: 25));
      await d.flush();
      expect(server.requests, hasLength(1));
      expect(d.pending, 0);
    });

    test('OP-95 a batch the server refuses is not resent', () async {
      final Server server = Server(
        (hc.Request r) => problem(422, 'validation_failed'),
      );
      final RelayDisplayedNotifications d = reporter(server);
      await d.report(ntf1);
      await d.flush();
      await d.flush();
      expect(server.requests, hasLength(1));
      expect(d.pending, 0);
    });

    test('OP-95 a push shown with fetched content is reported', () async {
      final Server server = Server((hc.Request r) => displayedAccepted());
      final RelayHttp core = httpCore(server);
      final MemoryRelayKeyValueStore store = MemoryRelayKeyValueStore();
      final RelayDisplayedNotifications d = RelayDisplayedNotifications(
        http: core,
        enabled: true,
        clock: FakeClock(),
        periodic: Ticks().call,
      );
      final RelayPushHandler h = RelayPushHandler(
        adapter: FakePushAdapter(),
        receipts: RelayReceiptQueue(http: core, store: store),
        store: store,
        contentSource: _Source(),
        displayedNotifications: d,
        onSync: (int? _) async => null,
      );
      await h.handle(<String, Object?>{
        'data': <String, Object?>{'relay_id': dlv1},
      });
      await d.flush();
      expect(server.calls, <String>[
        'POST /v1/subscriber/push_receipts',
        'POST $path',
      ]);
      expect(
        displayedNotifications(server.requests.last).single['digest'],
        ntfDigest,
      );
    });

    test('OP-95 going to background sends the queue', () async {
      final Server server = Server((hc.Request r) => displayedAccepted());
      final RelayClient client = RelayClient(
        baseUrl: base,
        tokenProvider: TokenSource().call,
        httpClient: server.client,
        transports: <RelayRealtimeTransport>[],
        random: FakeRandom(),
        delay: Delays().call,
        clock: FakeClock(),
        reportDisplayedNotifications: true,
        periodic: Ticks().call,
      );
      await client.reportDisplayedNotification(ntf1);
      expect(server.requests, isEmpty);
      await client.background();
      await client.displayedNotifications.flush();
      expect(server.calls, <String>['POST $path']);
      await client.dispose();
    });

    test('OP-95 the client does not report unless opted in', () async {
      final Server server = Server((hc.Request r) => displayedAccepted());
      final RelayClient client = RelayClient(
        baseUrl: base,
        tokenProvider: TokenSource().call,
        httpClient: server.client,
        transports: <RelayRealtimeTransport>[],
        random: FakeRandom(),
        delay: Delays().call,
      );
      await client.reportDisplayedNotification(ntf1);
      await client.background();
      expect(client.displayedNotifications.pending, 0);
      expect(server.requests, isEmpty);
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
