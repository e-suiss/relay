import '../core/http.dart';
import '../generated/models.dart';
import '../generated/operations.dart';
import 'adapter.dart';

// CH-33
/// The default source: fetches the content of a delivery from Relay with the subscriber token; any failure gives null, so the generic text is shown and content never falls back into the push payload.
class RelayApiPushContentSource implements RelayPushContentSource {
  /// Creates the source.
  const RelayApiPushContentSource(this.http);

  /// The HTTP core.
  final RelayHttp http;

  @override
  Future<RelayPushContent?> fetch(String deliveryId) async {
    try {
      final RelayResponse r = await http.send(
        RelayOperation.getMyPushContent,
        pathParams: <String, String>{'delivery_id': deliveryId},
      );
      return relayPushContentOf(PushContent.fromJson(r.json));
    } on Object {
      return null;
    }
  }
}

// CH-33
/// The shown content of fetched push content, or null when it carries neither a title nor a body.
RelayPushContent? relayPushContentOf(PushContent push) {
  String? text(String key) {
    final Object? value = push.content[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  final String? title = text('title');
  final String? body = text('body');
  if (title == null && body == null) return null;
  return RelayPushContent(
    title: title ?? '',
    body: body ?? '',
    url: text('url'),
    notificationId: push.notificationId,
  );
}
