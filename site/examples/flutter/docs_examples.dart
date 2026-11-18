import 'package:esuiss_relay/esuiss_relay.dart';
import 'package:flutter/material.dart';

class MyBackend {
  Future<({String accessToken, DateTime expiresAt})> relaySubscriberToken({
    required bool force,
  }) async =>
      (
        accessToken: force ? 'fresh' : 'cached',
        expiresAt: DateTime.now().add(const Duration(minutes: 15)),
      );
}

final MyBackend myBackend = MyBackend();

Future<RelayClient> startRelay() async {
  // #region client
  final relay = RelayClient(
    baseUrl: Uri.parse('https://relay.example.com'),
    tokenProvider: ({required bool forceRefresh}) async {
      final t = await myBackend.relaySubscriberToken(force: forceRefresh);
      return SubscriberToken(t.accessToken, expiresAt: t.expiresAt);
    },
    categories: const [
      RelayCategory('order_updates', RelayMessageClass.transactional),
      RelayCategory('campaigns', RelayMessageClass.marketing),
    ],
    locale: 'tr-TR',
    timezone: 'Europe/Istanbul',
  );

  await relay.start();
  RelayLifecycleObserver(relay).attach();
  // #endregion client
  return relay;
}

Widget inboxScreen(RelayClient relay, VoidCallback openInbox) {
  // #region inbox
  return RelayScope(
    client: relay,
    child: Scaffold(
      appBar: AppBar(actions: [RelayInboxBell(onPressed: openInbox)]),
      body: const RelayInboxList(),
    ),
  );
  // #endregion inbox
}
