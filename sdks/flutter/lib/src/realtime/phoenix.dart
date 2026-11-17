import 'dart:async';
import 'dart:convert';

import '../core/boundary.dart';
import 'transport.dart';

/// A connected WebSocket.
abstract interface class RelayWebSocket {
  /// Incoming text messages.
  Stream<String> get messages;

  /// Sends a text message.
  void send(String data);

  /// Closes the socket.
  Future<void> close();

  /// The close code once closed.
  int? get closeCode;

  /// The close reason once closed.
  String? get closeReason;
}

/// Opens a WebSocket with subprotocols.
typedef RelayWebSocketConnector = Future<RelayWebSocket> Function(
  Uri uri,
  List<String> protocols,
);

/// The Phoenix subprotocol carrying the subscriber token.
String relayPhoenixTokenProtocol(String token) =>
    'base64url.bearer.phx.${base64Url.encode(utf8.encode(token)).replaceAll('=', '')}';

// IN-23
// IN-58
/// The Phoenix Channels v2 WebSocket transport of the inbox stream.
class RelayPhoenixTransport implements RelayRealtimeTransport {
  /// Creates the transport.
  RelayPhoenixTransport({
    required this.baseUrl,
    required this.connector,
    this.heartbeat = const Duration(seconds: 15),
  });

  /// The region base URL.
  final Uri baseUrl;

  /// Opens sockets.
  final RelayWebSocketConnector connector;

  /// The heartbeat interval.
  final Duration heartbeat;

  RelayWebSocket? _socket;
  StreamSubscription<String>? _sub;
  Timer? _timer;
  StreamController<RelayRealtimeFrame>? _controller;
  int _ref = 0;
  String? _joinRef;
  String? _pendingHeartbeat;
  String? _joinPushRef;

  @override
  String get name => 'websocket';

  String _next() => '${++_ref}';

  /// The socket URL.
  Uri url({String? deviceId}) {
    RelayBoundary.check('GET', relayWebSocketPath);
    final String prefix = baseUrl.path.endsWith('/')
        ? baseUrl.path.substring(0, baseUrl.path.length - 1)
        : baseUrl.path;
    return baseUrl.replace(
      scheme: baseUrl.scheme == 'http' ? 'ws' : 'wss',
      path: '$prefix$relayWebSocketPath',
      queryParameters: <String, String>{'vsn': '2.0.0', 'device_id': ?deviceId},
    );
  }

  @override
  Stream<RelayRealtimeFrame> open({
    required String token,
    String? cursor,
    String? deviceId,
  }) {
    final StreamController<RelayRealtimeFrame> controller =
        StreamController<RelayRealtimeFrame>();
    _controller = controller;
    controller.onListen = () {
      unawaited(_run(controller, token, cursor, deviceId));
    };
    controller.onCancel = close;
    return controller.stream;
  }

  void _push(
    String? joinRef,
    String topic,
    String event,
    Object? payload, {
    String? ref,
  }) {
    _socket?.send(
      jsonEncode(<Object?>[joinRef, ref ?? _next(), topic, event, payload]),
    );
  }

  Future<void> _run(
    StreamController<RelayRealtimeFrame> controller,
    String token,
    String? cursor,
    String? deviceId,
  ) async {
    final RelayWebSocket socket;
    try {
      socket = await connector(url(deviceId: deviceId), <String>[
        'phoenix',
        relayPhoenixTokenProtocol(token),
      ]);
    } on Object {
      _fail(controller, const RelayRealtimeClosed('connect_failed'));
      return;
    }
    if (controller.isClosed) {
      await socket.close();
      return;
    }
    _socket = socket;
    _sub = socket.messages.listen(
      (String text) => _onMessage(controller, text),
      onDone: () => _fail(controller, relayClassifyClose(socket.closeReason)),
      onError: (Object _) =>
          _fail(controller, const RelayRealtimeClosed('socket_error')),
    );
    final String joinRef = _next();
    _joinRef = joinRef;
    _joinPushRef = joinRef;
    _push(joinRef, 'inbox', 'phx_join', <String, Object?>{
      'cursor': ?cursor,
    }, ref: joinRef);
    _timer = Timer.periodic(heartbeat, (_) {
      if (_pendingHeartbeat != null) {
        _fail(controller, const RelayRealtimeClosed('heartbeat_timeout'));
        return;
      }
      final String ref = _next();
      _pendingHeartbeat = ref;
      _push(null, 'phoenix', 'heartbeat', const <String, Object?>{}, ref: ref);
    });
  }

  void _onMessage(
    StreamController<RelayRealtimeFrame> controller,
    String text,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (decoded is! List<Object?> || decoded.length != 5) return;
    final Object? ref = decoded[1];
    final Object? topic = decoded[2];
    final Object? event = decoded[3];
    final Object? payload = decoded[4];
    if (event == 'phx_reply') {
      if (ref == _pendingHeartbeat) {
        _pendingHeartbeat = null;
        return;
      }
      if (ref == _joinPushRef && payload is Map<String, Object?>) {
        _joinPushRef = null;
        if (payload['status'] == 'ok') {
          if (!controller.isClosed) controller.add(const RelayRealtimeOpened());
        } else {
          final Object? response = payload['response'];
          final Object? reason = response is Map<String, Object?>
              ? response['reason']
              : null;
          _fail(
            controller,
            relayClassifyClose(reason is String ? reason : 'join_refused'),
          );
        }
      }
      return;
    }
    if (topic != 'inbox') return;
    if (event == 'phx_error' || event == 'phx_close') {
      _fail(controller, RelayRealtimeClosed(event! as String));
      return;
    }
    if (payload is Map<String, Object?> && payload['t'] == event) {
      if (!controller.isClosed) {
        controller.add(RelayRealtimeEnvelopeFrame(payload));
      }
    }
  }

  void _fail(
    StreamController<RelayRealtimeFrame> controller,
    RelayRealtimeClosed reason,
  ) {
    if (!controller.isClosed) {
      controller.addError(reason);
      unawaited(controller.close());
    }
    unawaited(close());
  }

  @override
  Future<void> refreshToken(String token) async {
    final String? joinRef = _joinRef;
    if (joinRef == null) return;
    _push(joinRef, 'inbox', 'auth.refresh', <String, Object?>{'token': token});
  }

  @override
  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    _pendingHeartbeat = null;
    _joinRef = null;
    final StreamSubscription<String>? sub = _sub;
    _sub = null;
    final RelayWebSocket? socket = _socket;
    _socket = null;
    await sub?.cancel();
    await socket?.close();
    final StreamController<RelayRealtimeFrame>? c = _controller;
    _controller = null;
    if (c != null && !c.isClosed) unawaited(c.close());
  }
}
