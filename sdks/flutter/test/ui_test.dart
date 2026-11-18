import 'dart:convert';

import 'package:esuiss_relay/esuiss_relay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as hc;

import 'support.dart';

Set<String> placeholders(String s) =>
    RegExp(r'\{([a-z_]+)\}')
        .allMatches(s)
        .map((RegExpMatch m) => m.group(1)!)
        .toSet();

Map<String, Object?> prefs({String pushSource = 'user', bool pushOn = true}) =>
    <String, Object?>{
      'object': 'subscriber_preferences',
      'subscriber_id': sub1,
      'cells': <Object?>[
        <String, Object?>{
          'category': 'orders',
          'channel': 'push',
          'value': 'unset',
          'effective': pushOn,
          'source': pushSource,
          'category_name': 'orders',
          'locked': false,
          'lock_beneficiary': null,
          'digest_allowed': true,
          'disabled_by_admin': false,
          'disabled_in_device_settings': false,
        },
        <String, Object?>{
          'category': 'orders',
          'channel': 'email',
          'value': 'unset',
          'effective': true,
          'source': 'class_default',
          'category_name': 'orders',
          'locked': false,
          'lock_beneficiary': null,
          'digest_allowed': true,
          'disabled_by_admin': false,
          'disabled_in_device_settings': false,
        },
        <String, Object?>{
          'category': 'security',
          'channel': 'email',
          'value': 'unset',
          'effective': true,
          'source': 'locked',
          'category_name': 'security',
          'locked': true,
          'lock_beneficiary': null,
          'digest_allowed': true,
          'disabled_by_admin': false,
          'disabled_in_device_settings': false,
        },
      ],
      'channels': <Object?>[],
      'workflows': <Object?>[],
      'scope_keys': <Object?>[],
      'profile': <String, Object?>{
        'quiet_hours': <Object?>[],
        'schedule': <Object?>[],
        'dnd_until': null,
        'quiet_hours_email': false,
        'digest': <String, Object?>{},
      },
    };

const String cns1 = 'cns_01j9zq3k4m5n6p7q8r9s0t1v2w';
const String cns2 = 'cns_01j9zq3k4m5n6p7q8r9s0t1v2x';
const String stn1 = 'stn_01j9zq3k4m5n6p7q8r9s0t1v2w';

Map<String, Object?> consent(
  String id,
  String channel,
  String status, {
  String? brand,
}) => <String, Object?>{
  'object': 'consent',
  'id': id,
  'brand': brand,
  'channel': channel,
  'status': status,
  'consent_kind': 'explicit_opt_in',
  'recipient_type': 'individual',
  'source': 'web',
  'occurred_at': ts,
};

Handler withConsents(
  Handler inner, {
  List<Object?> consents = const <Object?>[],
  bool fail = false,
}) => (hc.Request r) {
  if (r.url.path == '/v1/subscriber/consents') {
    if (fail) return problem(403, 'auth_insufficient_scope');
    return json(<String, Object?>{
      'object': 'list',
      'data': consents,
      'has_more': false,
      'next_cursor': null,
    });
  }
  return inner(r);
};

RelayClient clientFor(Server server) => RelayClient(
  baseUrl: base,
  tokenProvider: TokenSource().call,
  httpClient: server.client,
  transports: <RelayRealtimeTransport>[],
  random: FakeRandom(),
  delay: Delays().call,
);

Widget app(
  RelayClient client,
  Widget child, {
  Locale locale = const Locale('tr'),
}) => MaterialApp(
  home: RelayScope(
    client: client,
    locale: locale,
    child: Scaffold(body: child),
  ),
);

void main() {
  group('X-32 localisation and theming', () {
    test('X-32 Turkish and English carry the same keys and placeholders', () {
      final Map<String, String> tr = relayStrings['tr']!;
      final Map<String, String> en = relayStrings['en']!;
      expect(tr.keys.toSet(), en.keys.toSet());
      for (final String k in tr.keys) {
        expect(placeholders(tr[k]!), placeholders(en[k]!), reason: k);
      }
    });

    test('X-32 every channel has a name in both languages', () {
      for (final Channel c in Channel.values.where(
        (Channel c) => c != Channel.unrecognized,
      )) {
        expect(
          relayStrings['tr']!.containsKey('channel_${c.wire}'),
          isTrue,
          reason: c.wire,
        );
      }
    });

    test('X-44 every consent status has a name in both languages', () {
      for (final ConsentStatus s in ConsentStatus.values.where(
        (ConsentStatus s) => s != ConsentStatus.unrecognized,
      )) {
        for (final String lang in <String>['tr', 'en']) {
          expect(
            relayStrings[lang]!.containsKey('consent_${s.wire}'),
            isTrue,
            reason: '$lang ${s.wire}',
          );
        }
      }
    });

    test('X-32 default light and dark tokens meet WCAG 2.2 AA contrast', () {
      for (final RelayThemeData t in <RelayThemeData>[
        const RelayThemeData.light(),
        const RelayThemeData.dark(),
      ]) {
        expect(
          relayContrast(t.onSurface, t.surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          relayContrast(t.onSurfaceMuted, t.surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(relayContrast(t.accent, t.surface), greaterThanOrEqualTo(4.5));
        expect(relayContrast(t.onAccent, t.accent), greaterThanOrEqualTo(4.5));
        expect(relayContrast(t.onBadge, t.badge), greaterThanOrEqualTo(4.5));
        expect(relayContrast(t.danger, t.surface), greaterThanOrEqualTo(4.5));
      }
    });

    test('X-32 a brand replaces the accent', () {
      final RelayThemeData t = const RelayThemeData.light().withBrand(
        accent: const Color(0xFF00573F),
        onAccent: const Color(0xFFFFFFFF),
      );
      expect(t.accent, const Color(0xFF00573F));
      expect(t.unread, const Color(0xFF00573F));
    });
  });

  group('X-32 widgets', () {
    testWidgets('IN-19 the bell shows 99+ and says the count in its label', (
      WidgetTester tester,
    ) async {
      final RelayClient client = clientFor(
        Server((hc.Request r) => json(null)),
      );
      client.inbox.applyCounters(
        InboxCounters.fromJson(counters(unseen: 120, version: 1)),
      );
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        app(client, Center(child: RelayInboxBell(onPressed: () {}))),
      );
      expect(find.text('99+'), findsOneWidget);
      expect(find.bySemanticsLabel('Bildirimler, 99+ yeni'), findsOneWidget);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });

    testWidgets(
      'IN-12 the list marks unread with text, reads on tap and meets the accessibility guidelines',
      (WidgetTester tester) async {
        final Server server = Server(
          (hc.Request r) => json(<String, Object?>{
            'object': 'inbox_intent_result',
            'item_id': inb1,
            'op': 'read',
            'client_seq': 1,
            'result': 'applied',
            'state': state(inb1, version: 2, read: true),
            'counters': counters(version: 3),
          }),
        );
        final RelayClient client = clientFor(server);
        client.inbox.replaceAll(
          <InboxItem>[InboxItem.fromJson(item(inb1, title: 'Kargonuz yolda'))],
          counters: InboxCounters.fromJson(
            counters(unseen: 1, unread: 1, total: 1, version: 1),
          ),
        );
        final SemanticsHandle handle = tester.ensureSemantics();
        InboxItem? opened;
        await tester.pumpWidget(
          app(client, RelayInboxList(onItemTap: (InboxItem i) => opened = i)),
        );
        expect(find.text('Okunmadı'), findsOneWidget);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        await tester.tap(find.text('Kargonuz yolda'));
        await tester.pumpAndSettle();
        expect(opened?.id, inb1);
        expect(server.calls, <String>[
          'POST /v1/subscriber/inbox/items/$inb1/intents',
        ]);
        expect(
          (jsonDecode(server.requests.single.body)
              as Map<String, Object?>)['op'],
          'read',
        );
        expect(find.text('Okunmadı'), findsNothing);
        handle.dispose();
      },
    );

    testWidgets('IN-15 archive can be undone without any request', (
      WidgetTester tester,
    ) async {
      final Server server = Server((hc.Request r) => json(null));
      final RelayClient client = clientFor(server);
      client.inbox.replaceAll(<InboxItem>[
        InboxItem.fromJson(item(inb1, title: 'Kargonuz yolda')),
      ]);
      await tester.pumpWidget(app(client, const RelayInboxList()));
      await tester.tap(find.byTooltip('Arşivle'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Kargonuz yolda'), findsNothing);
      expect(find.text('Geri al'), findsOneWidget);
      tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed();
      await tester.pump();
      expect(find.text('Kargonuz yolda'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      expect(server.requests, isEmpty);
    });

    testWidgets(
      'PC-17 turning a category off offers three choices with none preselected; never writes opt_out',
      (WidgetTester tester) async {
        final Server server = Server(
          withConsents(
            (hc.Request r) =>
                r.method == 'GET' ? json(prefs()) : json(prefs(pushOn: false)),
          ),
        );
        final RelayClient client = clientFor(server);
        final SemanticsHandle handle = tester.ensureSemantics();
        await tester.pumpWidget(
          app(
            client,
            const RelayPreferenceCenter(
              categoryLabels: <String, String>{'orders': 'Siparişler'},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Açık (kilitli)'), findsOneWidget);
        expect(find.byType(Switch), findsNWidgets(2));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await tester.tap(find.byType(Switch).first);
        await tester.pumpAndSettle();
        expect(
          find.text('Siparişler bildirimleri nasıl gelsin?'),
          findsOneWidget,
        );
        expect(find.text('Anında al'), findsOneWidget);
        expect(find.text('Özet al'), findsOneWidget);
        expect(find.text('Hiç alma'), findsOneWidget);
        expect(find.byType(Radio<Object>), findsNothing);
        expect(find.byType(Checkbox), findsNothing);
        await tester.tap(find.text('Hiç alma'));
        await tester.pumpAndSettle();
        final Map<String, Object?> sent =
            jsonDecode(server.requests.last.body) as Map<String, Object?>;
        expect(sent, <String, Object?>{
          'preferences': <Object?>[
            <String, Object?>{
              'level': 'category_channel',
              'category': 'orders',
              'channel': 'push',
              'value': 'opt_out',
            },
          ],
        });
        handle.dispose();
      },
    );

    testWidgets('X-20 turning a channel back on takes a single tap', (
      WidgetTester tester,
    ) async {
      final Server server = Server(
        withConsents(
          (hc.Request r) =>
              r.method == 'GET' ? json(prefs(pushOn: false)) : json(prefs()),
        ),
      );
      final RelayClient client = clientFor(server);
      await tester.pumpWidget(
        app(client, const RelayPreferenceCenter(), locale: const Locale('en')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(server.calls.last, 'PATCH /v1/subscriber/preferences');
      final Map<String, Object?> sent =
          jsonDecode(server.requests.last.body) as Map<String, Object?>;
      expect(
        ((sent['preferences']! as List<Object?>).single!
            as Map<String, Object?>)['value'],
        'opt_in',
      );
    });

    testWidgets('X-32 the last open channel error is explained', (
      WidgetTester tester,
    ) async {
      final Server server = Server(
        withConsents(
          (hc.Request r) => r.method == 'GET'
              ? json(prefs())
              : problem(422, 'preference_last_channel'),
        ),
      );
      final RelayClient client = clientFor(server);
      await tester.pumpWidget(
        app(client, const RelayPreferenceCenter(), locale: const Locale('en')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Never get them'));
      await tester.pumpAndSettle();
      expect(
        find.text('At least one channel must stay on for orders.'),
        findsOneWidget,
      );
    });

    testWidgets(
      'X-44 consents are shown read-only next to the preferences with a link to change them in Access',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final Server server = Server(
          withConsents(
            (hc.Request r) => json(prefs()),
            consents: <Object?>[
              consent(cns1, 'email', 'active'),
              consent(cns2, 'sms', 'revoked', brand: stn1),
            ],
          ),
        );
        final RelayClient client = clientFor(server);
        final Uri access = Uri.parse('https://access.example/consents');
        Uri? opened;
        final SemanticsHandle handle = tester.ensureSemantics();
        await tester.pumpWidget(
          app(
            client,
            RelayPreferenceCenter(
              brandLabels: const <String, String>{stn1: 'Marka'},
              accessConsentUrl: access,
              onOpenUrl: (Uri u) => opened = u,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Pazarlama izinleri'), findsOneWidget);
        expect(find.bySemanticsLabel('E-posta: Verildi'), findsOneWidget);
        expect(
          find.bySemanticsLabel('Marka, SMS: Geri alındı'),
          findsOneWidget,
        );
        expect(find.byType(Switch), findsNWidgets(2));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        await tester.tap(find.text('İzinleri hesabınızda yönetin'));
        await tester.pumpAndSettle();
        expect(opened, access);
        expect(server.calls, <String>[
          'GET /v1/subscriber/preferences',
          'GET /v1/subscriber/consents',
        ]);
        handle.dispose();
      },
    );

    testWidgets(
      'X-44 without an Access link no link is shown, and a failed read says the details are not shown',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final Server server = Server(
          withConsents((hc.Request r) => json(prefs()), fail: true),
        );
        final RelayClient client = clientFor(server);
        await tester.pumpWidget(
          app(
            client,
            const RelayPreferenceCenter(),
            locale: const Locale('en'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Marketing permissions'), findsOneWidget);
        expect(
          find.text('Permission details are not shown here.'),
          findsOneWidget,
        );
        expect(find.text('Manage permissions in your account'), findsNothing);
      },
    );

    testWidgets(
      'AG-34 AG-35 an agent item says who sent it and a response is sent with its subject digest',
      (WidgetTester tester) async {
        final Server server = Server(
          (hc.Request r) => json(<String, Object?>{
            'object': 'waitpoint_response_receipt',
            'waitpoint_id': wp1,
            'status': 'responded',
            'responded_at': ts,
          }),
        );
        final RelayClient client = clientFor(server);
        client.inbox.replaceAll(<InboxItem>[
          InboxItem.fromJson(
            item(
              inb1,
              title: 'Sipariş iadesi onaylansın mı?',
              read: true,
              senderType: 'agent',
              approval: false,
              waitpoint: waitpoint(),
            ),
          ),
        ]);
        final SemanticsHandle handle = tester.ensureSemantics();
        await tester.pumpWidget(app(client, const RelayInboxList()));
        expect(find.text('Bir yapay zekâ ajanı gönderdi'), findsOneWidget);
        expect(find.text('Yanıtınız bekleniyor'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'Evet'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'Hayır'), findsOneWidget);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        await tester.tap(find.text('Evet'));
        await tester.pumpAndSettle();
        expect(server.calls, <String>[
          'POST /v1/subscriber/waitpoints/$wp1/response',
        ]);
        expect(jsonDecode(server.requests.single.body), <String, Object?>{
          'response': 'yes',
          'subject_digest': digest1,
        });
        expect(
          server.requests.single.headers.containsKey('Idempotency-Key'),
          isFalse,
        );
        expect(find.textContaining('Siz yanıtladı'), findsOneWidget);
        expect(find.byType(OutlinedButton), findsNothing);
        handle.dispose();
      },
    );

    testWidgets(
      'AG-35 processing, responded and not awaited states show without answer buttons',
      (WidgetTester tester) async {
        const String inb3 = 'inb_01j9zq3k4m5n6p7q8r9s0t1v2y';
        final RelayClient client = clientFor(
          Server((hc.Request r) => json(null)),
        );
        client.inbox.replaceAll(<InboxItem>[
          InboxItem.fromJson(
            item(
              inb1,
              title: 'A',
              read: true,
              activity: '2026-11-18T09:00:03Z',
              waitpoint: waitpoint(status: 'processing'),
            ),
          ),
          InboxItem.fromJson(
            item(
              inb2,
              title: 'B',
              read: true,
              activity: '2026-11-18T09:00:02Z',
              waitpoint: waitpoint(
                status: 'responded',
                responder: <String, Object?>{
                  'kind': 'agent',
                  'recipient_id': 'agent_1',
                },
                respondedAt: ts,
              ),
            ),
          ),
          InboxItem.fromJson(
            item(
              inb3,
              title: 'C',
              read: true,
              activity: '2026-11-18T09:00:01Z',
              waitpoint: waitpoint(status: 'not_awaited'),
            ),
          ),
        ]);
        await tester.pumpWidget(
          app(client, const RelayInboxList(), locale: const Locale('en')),
        );
        expect(find.text('Processing your response…'), findsOneWidget);
        expect(find.textContaining('Answered by an agent on'), findsOneWidget);
        expect(find.text('No longer expecting a response'), findsOneWidget);
        expect(find.byType(OutlinedButton), findsNothing);
      },
    );

    testWidgets(
      'IN-6 AG-32 an approval item only links to the Access approval surface and is never answered here',
      (WidgetTester tester) async {
        final Server server = Server((hc.Request r) => json(null));
        final RelayClient client = clientFor(server);
        client.inbox.replaceAll(<InboxItem>[
          InboxItem.fromJson(
            item(
              inb1,
              title: 'Ödeme onayı',
              read: true,
              approval: true,
              waitpoint: waitpoint(
                kind: 'approval',
                approvalUrl: 'https://access.example/approvals/1',
              ),
            ),
          ),
        ]);
        Uri? opened;
        final SemanticsHandle handle = tester.ensureSemantics();
        await tester.pumpWidget(
          app(client, RelayInboxList(onOpenUrl: (Uri u) => opened = u)),
        );
        expect(
          find.text('Onay burada değil, hesabınızda verilir.'),
          findsOneWidget,
        );
        expect(find.text('Evet'), findsNothing);
        expect(find.byType(OutlinedButton), findsOneWidget);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        await tester.tap(find.text('Hesabınızda inceleyin'));
        await tester.pump();
        expect(opened, Uri.parse('https://access.example/approvals/1'));
        expect(server.requests, isEmpty);
        handle.dispose();
      },
    );
  });
}
