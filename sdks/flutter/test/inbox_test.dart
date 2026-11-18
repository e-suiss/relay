import 'dart:async';
import 'dart:convert';

import 'package:esuiss_relay/esuiss_relay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as hc;

import 'support.dart';

Map<String, Object?> body(hc.Request r) =>
    jsonDecode(r.body) as Map<String, Object?>;

Map<String, Object?> intentResult(
  String id,
  String op,
  int seq, {
  int version = 2,
  bool read = true,
}) => <String, Object?>{
  'object': 'inbox_intent_result',
  'item_id': id,
  'op': op,
  'client_seq': seq,
  'result': 'applied',
  'state': state(id, version: version, read: read),
  'counters': counters(version: 5),
};

void main() {
  group('IN-27 store', () {
    test('IN-27 drops items and counters whose version is not newer', () {
      final RelayInboxStore store = RelayInboxStore();
      expect(store.upsert(InboxItem.fromJson(item(inb1, version: 2))), isTrue);
      expect(
        store.upsert(InboxItem.fromJson(item(inb1, version: 2, title: 'dup'))),
        isFalse,
      );
      expect(
        store.upsert(InboxItem.fromJson(item(inb1, version: 1, title: 'old'))),
        isFalse,
      );
      expect(store.item(inb1)!.title, 'Title');
      expect(
        store.applyCounters(
          InboxCounters.fromJson(counters(version: 3, unseen: 4)),
        ),
        isTrue,
      );
      expect(
        store.applyCounters(
          InboxCounters.fromJson(counters(version: 3, unseen: 9)),
        ),
        isFalse,
      );
      expect(store.unseen, 4);
    });

    test('IN-27 a hidden item stays removed against an older update', () {
      final RelayInboxStore store = RelayInboxStore();
      store.upsert(InboxItem.fromJson(item(inb1, version: 1)));
      store.applyChanges(inb1, 3, <String, Object?>{'hidden': true});
      expect(store.items, isEmpty);
      expect(store.upsert(InboxItem.fromJson(item(inb1, version: 2))), isFalse);
    });
  });

  group('IN-12 IN-13 offline queue', () {
    late RelayInboxStore inbox;
    late MemoryRelayKeyValueStore kv;

    setUp(() {
      inbox = RelayInboxStore()
        ..replaceAll(
          <InboxItem>[
            InboxItem.fromJson(item(inb1, version: 1)),
            InboxItem.fromJson(item(inb2, version: 1)),
          ],
          counters: InboxCounters.fromJson(
            counters(unseen: 2, unread: 2, total: 2, version: 1),
          ),
        );
      kv = MemoryRelayKeyValueStore();
    });

    test('IN-13 keeps one intent per item in client_seq order and sends them when back online', () async {
      bool online = false;
      final Server server = Server((hc.Request r) {
        if (!online) throw hc.ClientException('offline');
        final Map<String, Object?> b = body(r);
        final String id = r.url.pathSegments[4];
        return json(
          intentResult(id, b['op']! as String, b['client_seq']! as int),
        );
      });
      final RelayIntentQueue queue = RelayIntentQueue(
        http: httpCore(server),
        store: kv,
        inbox: inbox,
      );
      await queue.enqueue(inb1, 'read');
      await queue.enqueue(inb2, 'archive');
      await queue.enqueue(inb1, 'archive');
      await queue.flush();
      final List<RelayQueuedIntent> waiting = await queue.entries();
      expect(
        waiting.map(
          (RelayQueuedIntent e) => '${e.itemId}:${e.op}:${e.clientSeq}',
        ),
        <String>['$inb2:archive:2', '$inb1:archive:3'],
      );
      expect(inbox.item(inb1)!.archived, isTrue);
      online = true;
      await queue.flush();
      expect(await queue.entries(), isEmpty);
      final List<hc.Request> sent = server.requests
          .where((hc.Request r) => r.body.isNotEmpty)
          .toList();
      expect(
        sent.map((hc.Request r) => body(r)['client_seq']),
        containsAllInOrder(<int>[2, 3]),
      );
      expect(sent.first.headers['Idempotency-Key'], isNotNull);
    });

    test('IN-12 a 409 is accepted silently and a notice is raised only for an on-screen change', () async {
      final Server server = Server(
        (hc.Request r) => problem(
          409,
          'inbox_item_conflict',
          extra: <String, Object?>{
            'current': state(inb1, version: 7, read: true),
          },
        ),
      );
      final RelayIntentQueue queue = RelayIntentQueue(
        http: httpCore(server),
        store: kv,
        inbox: inbox,
      );
      final List<RelayConflictNotice> notices = <RelayConflictNotice>[];
      final StreamSubscription<RelayConflictNotice> sub = queue.notices.listen(
        notices.add,
      );
      await queue.enqueue(inb1, 'unread');
      await queue.flush();
      expect(inbox.item(inb1)!.stateVersion, 7);
      expect(inbox.item(inb1)!.read, isTrue);
      expect(await queue.entries(), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(notices, isEmpty);
      await queue.enqueue(inb2, 'unread', interactive: true);
      await queue.flush();
      await Future<void>.delayed(Duration.zero);
      expect(notices.single.op, 'unread');
      expect(body(server.requests.last)['base_state_version'], 1);
      await sub.cancel();
    });

    test('IN-13 an old reverse intent never overrides a newer state from another device', () async {
      final Server server = Server(
        (hc.Request r) => json(intentResult(inb1, 'unread', 1)),
      );
      final RelayIntentQueue queue = RelayIntentQueue(
        http: httpCore(server),
        store: kv,
        inbox: inbox,
      );
      await queue.enqueue(inb1, 'unread');
      inbox.applyChanges(inb1, 4, <String, Object?>{'read': true});
      await queue.flush();
      expect(server.requests, isEmpty);
      expect(await queue.entries(), isEmpty);
    });

    test('IN-15 undo cancels an action before any request', () async {
      final RelayUndoBuffer undo = RelayUndoBuffer(
        window: const Duration(milliseconds: 10),
      );
      int commits = 0;
      undo.schedule(inb1, () async => commits++);
      expect(undo.undo(inb1), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(commits, 0);
      undo.schedule(inb1, () async => commits++);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(commits, 1);
    });
  });

  group('IN-28 IN-29 sync', () {
    test('IN-28 envelopes buffered during a cold sync are applied after the list by id and version', () async {
      late RelayInboxSync sync;
      final Server server = Server((hc.Request r) {
        sync.onEnvelope(
          envelope(
            'inbox.item_updated',
            <String, Object?>{
              'item_id': inb1,
              'state_version': 3,
              'changes': <String, Object?>{'read': true},
            },
            id: 'c9',
            version: 4,
          ),
        );
        return json(<String, Object?>{
          'object': 'list',
          'data': <Object?>[item(inb1, version: 2)],
          'has_more': true,
          'next_cursor': 'n1',
          'previous_cursor': null,
          'counters': counters(unread: 1, version: 3),
          'cursor': 'c5',
        });
      });
      final RelayInboxStore store = RelayInboxStore();
      sync = RelayInboxSync(http: httpCore(server), store: store);
      await sync.coldSync();
      expect(store.item(inb1)!.read, isTrue);
      expect(store.item(inb1)!.stateVersion, 3);
      expect(store.cursor, 'c9');
      expect(store.counters!.version, 4);
    });

    test(
      'IN-21 a fully listed inbox that disagrees with the counters is reported',
      () async {
        final Server server = Server((hc.Request r) {
          if (r.url.path.endsWith('/inconsistency')) {
            return json(<String, Object?>{
              'object': 'inbox_reconciliation',
              'result': 'repaired',
              'counters': counters(unread: 1, version: 9),
            });
          }
          return json(<String, Object?>{
            'object': 'list',
            'data': <Object?>[item(inb1)],
            'has_more': false,
            'next_cursor': null,
            'previous_cursor': null,
            'counters': counters(unread: 3, version: 2),
            'cursor': 'c1',
          });
        });
        final RelayInboxStore store = RelayInboxStore();
        await RelayInboxSync(http: httpCore(server), store: store).coldSync();
        expect(
          server.calls.last,
          'POST /v1/subscriber/inbox/counters/inconsistency',
        );
        expect(store.counters!.unread, 1);
      },
    );

    test('IN-29 a truncated delta goes back to a cold sync', () async {
      final Server server = Server((hc.Request r) {
        if (r.url.path.endsWith('/changes')) {
          return json(<String, Object?>{
            'object': 'inbox_changes',
            'changes': <Object?>[],
            'cursor': 'c7',
            'has_more': false,
            'truncated': true,
            'resync_required': false,
            'counters': counters(version: 2),
          });
        }
        return json(<String, Object?>{
          'object': 'list',
          'data': <Object?>[],
          'has_more': false,
          'next_cursor': null,
          'previous_cursor': null,
          'counters': counters(version: 3),
          'cursor': 'c8',
        });
      });
      final RelayInboxStore store = RelayInboxStore()..cursor = 'c1';
      await RelayInboxSync(http: httpCore(server), store: store).deltaSync();
      expect(server.calls, <String>[
        'GET /v1/subscriber/inbox/changes',
        'GET /v1/subscriber/inbox/items',
      ]);
      expect(server.requests.first.url.queryParameters['since'], 'c1');
      expect(store.cursor, 'c8');
    });
  });
}
