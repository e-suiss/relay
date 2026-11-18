import '../generated/operations.dart';
import 'errors.dart';

/// The path of the realtime WebSocket.
const String relayWebSocketPath = '/v1/realtime/websocket';

/// The path where displayed notification digests are reported.
const String relayDisplayedNotificationsPath =
    '/v1/subscriber/displayed_notifications';

// X-31
/// The calls a client may make: subscriber-token operations only; no event triggering, no profile or consent writes and no secret credentials.
abstract final class RelayBoundary {
  static final List<(String, RegExp)> _allowed = <(String, RegExp)>[
    for (final RelayOperation op in RelayOperation.values)
      (op.method, _pattern(op.path)),
    ('GET', _pattern(relayWebSocketPath)),
    ('POST', _pattern(relayDisplayedNotificationsPath)),
  ];

  static RegExp _pattern(String template) {
    final String body = template
        .split('/')
        .map(
          (String s) =>
              s.startsWith('{') && s.endsWith('}') ? '[^/]+' : RegExp.escape(s),
        )
        .join('/');
    return RegExp('^$body\$');
  }

  /// Whether the method and path are inside the boundary.
  static bool allows(String method, String path) => _allowed.any(
    ((String, RegExp) a) => a.$1 == method.toUpperCase() && a.$2.hasMatch(path),
  );

  /// Throws [RelayBoundaryError] for a call outside the boundary.
  static void check(String method, String path) {
    if (!allows(method, path)) throw RelayBoundaryError(method, path);
  }
}
