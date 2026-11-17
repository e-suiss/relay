import 'dart:async';
import 'dart:convert';

import 'package:esuiss_relay/esuiss_relay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as hc;
import 'package:http/testing.dart';

import 'support.dart';

class FakeSocket implements RelayWebSocket {
  FakeSocket(this.onSend);

  final void Function(FakeSocket socket, List<Object?> message) onSend;
  final StreamController<String> incoming = StreamController<String>();
  final List<List<Object?>> sent = <List<Object?>>[];

  @override
  int? closeCode;

  @override
  String? closeReason;

  @override
  Stream<String> get messages => incoming.stream;

  @override
  void send(String data) {
    final List<Object?> m = jsonDecode(data) as List<Object?>;
    sent.add(m);
    onSend(this, m);
  }

  void push(List<Object?> m) => incoming.add(jsonEncode(m));

  void serverClose(int code, String reason) {
    closeCode = code;
    closeReason = reason;
    unawaited(incoming.close());
  }

  @override
  Future<void> close() async {
    if (!incoming.isClosed) unawaited(incoming.close());
  }
}

class FakeTransport implements RelayRealtimeTransport {
  FakeTransport(this.name, this.behaviour);

  @override
  final String name;

  final void Function(StreamController<RelayRealtimeFrame> c, int attempt) behaviour;
  int opens = 0;
  final List<String> tokens = <String>[];
  StreamController<RelayRealtimeFrame>? _c;

  @override
  Stream<RelayRealtimeFrame> open({required String token, String? cursor, String? deviceId}) {
    final StreamController<RelayRealtimeFrame> c = StreamController<RelayRealtimeFrame>();
    _c = c;
    final int n = opens++;
    tokens.add(token);
    c.onListen = () => behaviour(c, n);
    return c.stream;
  }

  @override
  Future<void> refreshToken(String token) async {}

  @override
  Future<void> close() async {
    final StreamController<RelayRealtimeFrame>? c = _c;
    _c = null;
    if (c != null && !c.isClosed) unawaited(c.close());
  }
}

void failWith(StreamController<RelayRealtimeFrame> c, RelayRealtimeClosed reason) {
  c.addError(reason);
  unawaited(c.close());
}

RelayRealtime manager(
  List<RelayRealtimeTransport> transports, {
  TokenSource? tokens,
  Delays? delays,
  List<Map<String, Object?>>? envelopes,
}) {
  final TokenSource t = tokens ?? TokenSource();
  return RelayRealtime(
    transports: transports,
    http: RelayHttp(baseUrl: base, tokenProvider: t.call, client: MockClient((hc.Request r) async => json(null))),
    onEnvelope: (Map<String, Object?> e) => envelopes?.add(e),
    cursor: () => 'c5',
    deviceId: () async => dev1,
    random: FakeRandom(),
    delay: (delays ?? Delays()).call,
  );
}

void main() {
  group('IN-23 Phoenix WebSocket', () {
    test('IN-23 joins the inbox topic with the token as subprotocol and delivers envelopes', () async {
      Uri? uri;
      List<String>? protocols;
      late FakeSocket socket;
      final RelayPhoenixTransport ws = RelayPhoenixTransport(
        baseUrl: base,
        connector: (Uri u, List<String> p) async {
          uri = u;
          protocols = p;
          socket = FakeSocket((FakeSocket s, List<Object?> m) {
            if (m[3] == 'phx_join') {
              s.push(<Object?>[m[0], m[1], 'inbox', 'phx_reply', <String, Object?>{'status': 'ok', 'response': <String, Object?>{}}]);
              s.push(<Object?>[m[0], null, 'inbox', 'inbox.counters_changed',
                  envelope('inbox.counters_changed', counters(), id: 'c6', version: 2)]);
            }
          });
          return socket;
        },
      );
      final List<Map<String, Object?>> envelopes = <Map<String, Object?>>[];
      final RelayRealtime rt = manager(<RelayRealtimeTransport>[ws], envelopes: envelopes);
      expect(await rt.start(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(uri.toString(), 'wss://relay.test/v1/realtime/websocket?vsn=2.0.0&device_id=$dev1');
      expect(protocols, <String>['phoenix', relayPhoenixTokenProtocol('token-1')]);
      expect(relayPhoenixTokenProtocol('token-1'), 'base64url.bearer.phx.dG9rZW4tMQ');
      expect(socket.sent.first.sublist(2), <Object?>['inbox', 'phx_join', <String, Object?>{'cursor': 'c5'}]);
      expect(envelopes.single['id'], 'c6');
      expect(rt.status.value, RelayRealtimeStatus.connected);
      await rt.stop();
    });

    test('IN-58 a 1008 auth_expired_token close refreshes the token and reconnects', () async {
      final List<List<String>> protocols = <List<String>>[];
      final RelayPhoenixTransport ws = RelayPhoenixTransport(
        baseUrl: base,
        connector: (Uri u, List<String> p) async {
          protocols.add(p);
          final int n = protocols.length;
          return FakeSocket((FakeSocket s, List<Object?> m) {
            if (m[3] != 'phx_join') return;
            if (n == 1) {
              s.serverClose(1008, 'auth_expired_token');
            } else {
              s.push(<Object?>[m[0], m[1], 'inbox', 'phx_reply', <String, Object?>{'status': 'ok', 'response': <String, Object?>{}}]);
            }
          });
        },
      );
      final TokenSource tokens = TokenSource();
      final RelayRealtime rt = manager(<RelayRealtimeTransport>[ws], tokens: tokens);
      expect(await rt.start(), isTrue);
      expect(tokens.forced, 1);
      expect(protocols[1][1], relayPhoenixTokenProtocol('token-2'));
      await rt.stop();
    });

    test('IN-52 a 1013 close waits the server retry-after', () async {
      int n = 0;
      final RelayPhoenixTransport ws = RelayPhoenixTransport(
        baseUrl: base,
        connector: (Uri u, List<String> p) async {
          n++;
          final int attempt = n;
          return FakeSocket((FakeSocket s, List<Object?> m) {
            if (m[3] != 'phx_join') return;
            if (attempt == 1) {
              s.serverClose(1013, 'retry-after=4');
            } else {
              s.push(<Object?>[m[0], m[1], 'inbox', 'phx_reply', <String, Object?>{'status': 'ok', 'response': <String, Object?>{}}]);
            }
          });
        },
      );
      final Delays delays = Delays();
      final RelayRealtime rt = manager(
        <RelayRealtimeTransport>[ws, FakeTransport('sse', (_, _) {})],
        delays: delays,
      );
      expect(await rt.start(), isTrue);
      expect(delays.waits.first, const Duration(seconds: 4));
      await rt.stop();
    });
  });

  group('IN-23 IN-34 fallback and reconnect', () {
    test('IN-23 falls back from WebSocket to SSE after two failed connects, with full-jitter waits', () async {
      final FakeTransport ws = FakeTransport('websocket', (StreamController<RelayRealtimeFrame> c, int _) {
        failWith(c, const RelayRealtimeClosed('connect_failed'));
      });
      final FakeTransport sse = FakeTransport('sse', (StreamController<RelayRealtimeFrame> c, int _) {
        c.add(const RelayRealtimeOpened());
      });
      final Delays delays = Delays();
      final RelayRealtime rt = manager(<RelayRealtimeTransport>[ws, sse, FakeTransport('long_poll', (_, _) {})], delays: delays);
      expect(await rt.start(), isTrue);
      expect(ws.opens, 2);
      expect(sse.opens, 1);
      expect(rt.transport, 'sse');
      expect(delays.waits, <Duration>[const Duration(milliseconds: 500), const Duration(milliseconds: 1000)]);
      await rt.stop();
      expect(rt.status.value, RelayRealtimeStatus.stopped);
    });

    test('IN-33 a suspension stops reconnecting', () async {
      final FakeTransport ws = FakeTransport('websocket', (StreamController<RelayRealtimeFrame> c, int _) {
        failWith(c, relayClassifyClose('auth_subscriber_suspended'));
      });
      final RelayRealtime rt = manager(<RelayRealtimeTransport>[ws]);
      expect(await rt.start(), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(ws.opens, 1);
      expect(rt.status.value, RelayRealtimeStatus.refused);
    });
  });

  group('IN-23 SSE and long-poll', () {
    test('IN-23 SSE resumes with Last-Event-ID and parses envelopes', () async {
      hc.BaseRequest? seen;
      final MockClient client = MockClient.streaming((hc.BaseRequest r, Stream<List<int>> _) async {
        seen = r;
        final String event = 'id: c7\nevent: inbox.counters_changed\ndata: '
            '${jsonEncode(envelope('inbox.counters_changed', counters(), id: 'c7'))}\n\n: keep-alive\n\n';
        return hc.StreamedResponse(Stream<List<int>>.value(utf8.encode(event)), 200);
      });
      final RelaySseTransport sse = RelaySseTransport(
        http: RelayHttp(baseUrl: base, tokenProvider: TokenSource().call, client: client),
      );
      final List<RelayRealtimeFrame> frames = <RelayRealtimeFrame>[];
      await expectLater(
        sse.open(token: 'tok', cursor: 'c6', deviceId: dev1).handleError((Object _) {}).toList().then(frames.addAll),
        completes,
      );
      expect(seen!.headers['Last-Event-ID'], 'c6');
      expect(seen!.headers['Authorization'], 'Bearer tok');
      expect(seen!.url.queryParameters['device_id'], dev1);
      expect(frames.first, isA<RelayRealtimeOpened>());
      expect((frames[1] as RelayRealtimeEnvelopeFrame).envelope['id'], 'c7');
    });

    test('IN-52 SSE 503 carries the server retry-after', () async {
      final MockClient client = MockClient((hc.Request r) async =>
          problem(503, 'service_unavailable', retryable: true, headers: <String, String>{'retry-after': '3'}));
      final RelaySseTransport sse = RelaySseTransport(
        http: RelayHttp(baseUrl: base, tokenProvider: TokenSource().call, client: client),
      );
      Object? error;
      await sse.open(token: 'tok').handleError((Object e) => error = e).toList();
      expect((error! as RelayRealtimeClosed).retryAfter, const Duration(seconds: 3));
    });

    test('IN-23 long-poll yields envelopes and follows the cursor', () async {
      final List<String?> cursors = <String?>[];
      final MockClient client = MockClient((hc.Request r) async {
        cursors.add(r.url.queryParameters['cursor']);
        return json(<String, Object?>{
          'events': <Object?>[envelope('inbox.counters_changed', counters(), id: 'c${cursors.length}')],
          'cursor': 'c${cursors.length}',
        });
      });
      final RelayPollTransport poll = RelayPollTransport(
        http: RelayHttp(baseUrl: base, tokenProvider: TokenSource().call, client: client),
      );
      final List<RelayRealtimeFrame> frames =
          await poll.open(token: 'tok', cursor: 'c0').take(5).toList();
      expect(frames[0], isA<RelayRealtimeOpened>());
      expect((frames[1] as RelayRealtimeEnvelopeFrame).envelope['id'], 'c1');
      expect((frames[2] as RelayRealtimeCursorFrame).cursor, 'c1');
      expect(cursors.take(2), <String?>['c0', 'c1']);
    });
  });

  group('IN-35 lifecycle', () {
    test('IN-35 foreground runs counters, stream, sync, then the offline queue', () async {
      final List<String> log = <String>[];
      final Server server = Server((hc.Request r) {
        log.add('${r.method} ${r.url.pathSegments.last}');
        if (r.url.path.endsWith('/counters')) return json(counters(version: 1));
        if (r.url.path.endsWith('/items')) {
          return json(<String, Object?>{
            'object': 'list',
            'data': <Object?>[item(inb1)],
            'has_more': true,
            'next_cursor': 'n',
            'previous_cursor': null,
            'counters': counters(unread: 1, version: 2),
            'cursor': 'c1',
          });
        }
        return json(<String, Object?>{
          'object': 'inbox_intent_result',
          'item_id': inb1,
          'op': 'read',
          'client_seq': 1,
          'result': 'applied',
          'state': state(inb1, version: 2, read: true),
          'counters': counters(version: 3),
        });
      });
      final FakeTransport stream = FakeTransport('websocket', (StreamController<RelayRealtimeFrame> c, int _) {
        log.add('open');
        c.add(const RelayRealtimeOpened());
      });
      final RelayClient client = RelayClient(
        baseUrl: base,
        tokenProvider: TokenSource().call,
        httpClient: server.client,
        transports: <RelayRealtimeTransport>[stream],
        random: FakeRandom(),
        delay: Delays().call,
      );
      await client.intents.enqueue(inb1, 'read');
      await client.foreground();
      expect(log, <String>['GET counters', 'open', 'GET items', 'POST intents']);
      await client.background();
      expect(client.realtime.status.value, RelayRealtimeStatus.stopped);
      await client.dispose();
    });
  });
}
