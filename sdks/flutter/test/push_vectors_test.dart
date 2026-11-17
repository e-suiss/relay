import 'package:esuiss_relay/esuiss_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

DevicePlatform platformOf(Object? name) =>
    DevicePlatform.fromWire(name! as String);

RelayCategory category(Object? raw) {
  final Map<String, Object?> e = raw! as Map<String, Object?>;
  return RelayCategory(
    e['key']! as String,
    RelayMessageClass.fromWire(e['class']! as String),
    critical: e['critical'] == true,
  );
}

void main() {
  group('CH-30 CH-65 stable Android channels', () {
    final Map<String, Object?> v = vector('android_channels.json');

    for (final Object? raw in v['cases']! as List<Object?>) {
      final Map<String, Object?> c = raw! as Map<String, Object?>;
      test('CH-30 ${c['name']}', () {
        final List<RelayCategory> categories = <RelayCategory>[
          for (final Object? e in c['categories']! as List<Object?>)
            category(e),
        ];
        final List<Map<String, Object?>> actual = <Map<String, Object?>>[
          for (final RelayAndroidChannel ch in relayAndroidChannels(categories))
            <String, Object?>{
              'id': ch.id,
              'category': ch.category,
              'level': ch.level.wire,
              'importance': ch.importance.wire,
              'bypass_dnd': ch.bypassDnd,
            },
        ];
        expect(actual, c['channels']);
      });
    }

    for (final Object? raw in v['invalid']! as List<Object?>) {
      final Map<String, Object?> c = raw! as Map<String, Object?>;
      test('CH-30 refuses ${c['name']}', () {
        expect(() {
          relayAndroidChannels(<RelayCategory>[
            for (final Object? e in c['categories']! as List<Object?>)
              category(e),
          ]);
        }, throwsArgumentError);
      });
    }

    test('CH-29 provisional authorisation only when every starting class is marketing or social', () {
      expect(
        relayUseProvisional(<RelayMessageClass>[
          RelayMessageClass.marketing,
          RelayMessageClass.social,
        ]),
        isTrue,
      );
      expect(
        relayUseProvisional(<RelayMessageClass>[
          RelayMessageClass.marketing,
          RelayMessageClass.security,
        ]),
        isFalse,
      );
      expect(
        relayUseProvisional(<RelayMessageClass>[
          RelayMessageClass.transactional,
        ]),
        isFalse,
      );
      expect(relayUseProvisional(<RelayMessageClass>[]), isFalse);
    });
  });

  group('CH-33 IN-38 push payloads', () {
    final Map<String, Object?> v = vector('push_payloads.json');

    for (final Object? raw in v['cases']! as List<Object?>) {
      final Map<String, Object?> c = raw! as Map<String, Object?>;
      test('CH-33 ${c['name']}', () {
        final RelayPushMessage? m = parseRelayPush(
          platformOf(c['platform']),
          c['payload']! as Map<String, Object?>,
        );
        final Map<String, Object?> expected =
            c['expected']! as Map<String, Object?>;
        final Map<String, Object?> actual = switch (m) {
          final RelayPushNotification n => <String, Object?>{
            'kind': 'notification',
            'delivery_id': n.deliveryId,
            'content_free': n.contentFree,
            'topic': n.topic,
            'url': n.url,
            'title': n.title,
            'body': n.body,
          },
          final RelayPushSync s => <String, Object?>{
            'kind': 'sync',
            'counter_version': s.counterVersion,
            'notification_id': null,
          },
          final RelayPushRead r => <String, Object?>{
            'kind': 'read',
            'counter_version': r.counterVersion,
            'notification_id': r.notificationId,
          },
          null => <String, Object?>{'kind': null},
        };
        expect(actual, expected);
      });
    }

    for (final Object? raw in v['ignored']! as List<Object?>) {
      final Map<String, Object?> c = raw! as Map<String, Object?>;
      test('CH-33 ignores ${c['name']}', () {
        expect(
          parseRelayPush(
            platformOf(c['platform']),
            c['payload']! as Map<String, Object?>,
          ),
          isNull,
        );
      });
    }

    test('CH-33 the generic fallback text matches the server neutral text', () {
      final Map<String, Object?> fallback =
          v['fallback']! as Map<String, Object?>;
      for (final String lang in <String>['tr', 'en']) {
        final Map<String, Object?> f = fallback[lang]! as Map<String, Object?>;
        final RelayNeutralText t = relayNeutralText(
          lang == 'tr' ? 'tr-TR' : 'en-GB',
        );
        expect(<String, Object?>{'title': t.title, 'body': t.body}, f);
      }
      expect(relayNeutralText(null).title, 'New notification');
    });
  });
}
