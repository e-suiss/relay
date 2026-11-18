import 'dart:io';

import 'package:esuiss_relay/esuiss_relay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('X-31 client boundary', () {
    test('X-31 every operation the SDK can call is a subscriber-token operation of the client family', () {
      for (final RelayOperation op in RelayOperation.values) {
        expect(
          op.path.startsWith('/v1/subscriber/') ||
              op.path.startsWith('/v1/realtime/'),
          isTrue,
          reason: op.path,
        );
      }
      expect(
        RelayOperation.values.map((RelayOperation o) => o.path),
        isNot(contains('/v1/subscriber/token')),
      );
    });

    test('X-31 triggering events, writing a subscriber profile or consents is refused before any request', () {
      const List<(String, String)> refused = <(String, String)>[
        ('POST', '/v1/events'),
        ('POST', '/v1/notifications'),
        ('PUT', '/v1/subscribers/sub_1'),
        ('PATCH', '/v1/subscribers/sub_1'),
        ('PATCH', '/v1/subscribers/sub_1/preferences'),
        ('POST', '/v1/subscribers/sub_1/consents'),
        ('POST', '/v1/subscriber/token'),
        ('DELETE', '/v1/subscriber/preferences'),
      ];
      for (final (String method, String path) in refused) {
        expect(
          RelayBoundary.allows(method, path),
          isFalse,
          reason: '$method $path',
        );
        expect(
          () => RelayBoundary.check(method, path),
          throwsA(isA<RelayBoundaryError>()),
        );
      }
      expect(
        RelayBoundary.allows('PATCH', '/v1/subscriber/preferences'),
        isTrue,
      );
      expect(RelayBoundary.allows('POST', '/v1/subscriber/devices'), isTrue);
      expect(RelayBoundary.allows('GET', '/v1/realtime/websocket'), isTrue);
      expect(
        RelayBoundary.allows('POST', relayDisplayedNotificationsPath),
        isTrue,
      );
    });

    test(
      'X-31 the library holds no server endpoint, API key or secret option',
      () {
        final List<File> files = Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((File f) => f.path.endsWith('.dart'))
            .toList();
        expect(files, isNotEmpty);
        final RegExp forbidden = RegExp(
          r"/v1/events|/v1/notifications|/v1/subscribers/|api_key|apiKey|client_secret|clientSecret|privateKey",
        );
        for (final File f in files) {
          expect(
            forbidden.hasMatch(f.readAsStringSync()),
            isFalse,
            reason: f.path,
          );
        }
      },
    );
  });
}
