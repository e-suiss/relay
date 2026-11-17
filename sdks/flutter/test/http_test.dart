import 'package:esuiss_relay/esuiss_relay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as hc;

import 'support.dart';

void main() {
  group('X-48 HTTP core', () {
    test('API-10 sends the pinned Relay-Version, the bearer token and an Idempotency-Key on mutations only', () async {
      final Server server = Server((hc.Request r) => r.method == 'GET'
          ? json(counters())
          : json(<String, Object?>{
              'object': 'inbox_read_all_result',
              'scope': 'all',
              'category': null,
              'updated': 0,
              'cut_off': ts,
              'counters': counters(version: 2),
            }));
      final RelayHttp http = httpCore(server);
      await http.send(RelayOperation.getMyInboxCounters);
      await http.send(RelayOperation.markAllMyInboxRead, body: <String, Object?>{});
      expect(server.requests[0].headers['Relay-Version'], relayApiVersion);
      expect(server.requests[0].headers['Authorization'], 'Bearer token-1');
      expect(server.requests[0].headers.containsKey('Idempotency-Key'), isFalse);
      expect(server.requests[1].headers['Idempotency-Key'], isNotNull);
      expect(relayApiVersion, '2026-11-01');
    });

    test('X-29 retries a retryable error with the same Idempotency-Key and honours Retry-After', () async {
      int n = 0;
      final Server server = Server((hc.Request r) {
        n++;
        if (n == 1) return problem(503, 'service_unavailable', retryable: true, headers: <String, String>{'retry-after': '2'});
        return json(<String, Object?>{'object': 'push_receipt', 'delivery_id': dlv1, 'receipt': 'displayed'}, status: 202);
      });
      final Delays delays = Delays();
      final RelayHttp http = httpCore(server, delays: delays);
      await http.send(RelayOperation.recordMyPushReceipt,
          body: <String, Object?>{'delivery_id': dlv1, 'receipt': 'displayed'});
      expect(server.requests, hasLength(2));
      expect(server.requests[0].headers['Idempotency-Key'], server.requests[1].headers['Idempotency-Key']);
      expect(delays.waits, <Duration>[const Duration(seconds: 2)]);
    });

    test('X-29 never retries a non-retryable error', () async {
      final Server server = Server((hc.Request r) => problem(422, 'validation_failed'));
      final RelayHttp http = httpCore(server);
      await expectLater(
        http.send(RelayOperation.updateMyPreferences, body: <String, Object?>{}),
        throwsA(isA<RelayValidationError>()),
      );
      expect(server.requests, hasLength(1));
    });

    test('X-29 retries network failures with full-jitter backoff, then raises a network error', () async {
      final Server server = Server((hc.Request r) => throw hc.ClientException('offline'));
      final Delays delays = Delays();
      final RelayHttp http = httpCore(server, delays: delays);
      await expectLater(http.send(RelayOperation.getMyInboxCounters), throwsA(isA<RelayNetworkError>()));
      expect(server.requests, hasLength(4));
      expect(delays.waits, <Duration>[
        const Duration(milliseconds: 500),
        const Duration(milliseconds: 1000),
        const Duration(milliseconds: 2000),
      ]);
    });

    test('X-31 asks the host for a fresh token once on an expired token', () async {
      final TokenSource tokens = TokenSource();
      int n = 0;
      final Server server = Server((hc.Request r) {
        n++;
        return n == 1 ? problem(401, 'auth_expired_token') : json(counters());
      });
      final RelayHttp http = httpCore(server, tokens: tokens);
      await http.send(RelayOperation.getMyInboxCounters);
      expect(tokens.forced, 1);
      expect(server.requests[1].headers['Authorization'], 'Bearer token-2');
    });

    test('X-29 maps errors to the typed hierarchy and the catalog retryable flag', () async {
      final Map<String, Type> cases = <String, Type>{};
      Future<void> check(int status, String code, Matcher type, bool retryable) async {
        final Server server = Server((hc.Request r) => problem(status, code, retryable: !retryable));
        final RelayHttp http = httpCore(server);
        try {
          await http.send(RelayOperation.getMyInboxCounters, retries: 0);
          fail('expected an error');
        } on RelayError catch (e) {
          expect(e, type);
          expect(e.retryable, retryable, reason: code);
          cases[code] = e.runtimeType;
        }
      }

      await check(401, 'auth_invalid_token', isA<RelayAuthError>(), false);
      await check(404, 'inbox_item_not_found', isA<RelayNotFoundError>(), false);
      await check(409, 'inbox_item_conflict', isA<RelayConflictError>(), false);
      await check(409, 'idempotency_key_in_progress', isA<RelayIdempotencyError>(), true);
      await check(429, 'rate_limited', isA<RelayRateLimitError>(), true);
      await check(429, 'quota_exhausted', isA<RelayRateLimitError>(), false);
      await check(500, 'internal_error', isA<RelayServerError>(), true);
      expect(cases, hasLength(7));
    });

    test('X-29 reads Retry-After as seconds or an HTTP date', () {
      expect(parseRetryAfter('7'), const Duration(seconds: 7));
      expect(
        parseRetryAfter('Wed, 18 Nov 2026 09:00:30 GMT', now: DateTime.utc(2026, 11, 18, 9)),
        const Duration(seconds: 30),
      );
      expect(parseRetryAfter('soon'), isNull);
    });

    test('X-31 refuses a base address without TLS', () {
      expect(
        () => RelayHttp(baseUrl: Uri.parse('http://relay.example.com'), tokenProvider: TokenSource().call),
        throwsArgumentError,
      );
    });

    test('IN-52 backoff is full jitter between zero and min(60 s, 2^attempt s)', () {
      final FakeRandom r = FakeRandom(0.999);
      expect(relayBackoff(0, r).inMilliseconds, lessThan(1000));
      expect(relayBackoff(3, r).inMilliseconds, lessThan(8000));
      expect(relayBackoff(10, r).inMilliseconds, lessThan(60000));
      expect(relayBackoff(10, FakeRandom(0)), Duration.zero);
    });
  });
}
