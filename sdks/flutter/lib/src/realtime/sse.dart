import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as hc;

import '../core/boundary.dart';
import '../core/http.dart';
import '../generated/operations.dart';
import 'transport.dart';

// IN-23
/// The Server-Sent Events transport of the inbox stream.
class RelaySseTransport implements RelayRealtimeTransport {
  /// Creates the transport.
  RelaySseTransport({required this.http});

  /// The HTTP core; its client streams the response.
  final RelayHttp http;

  StreamSubscription<String>? _sub;
  StreamController<RelayRealtimeFrame>? _controller;

  @override
  String get name => 'sse';

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

  Future<void> _run(
    StreamController<RelayRealtimeFrame> controller,
    String token,
    String? cursor,
    String? deviceId,
  ) async {
    const RelayOperation op = RelayOperation.streamRealtimeEvents;
    final Uri uri = http.url(
      op.path,
      query: <String, String?>{'device_id': deviceId},
    );
    RelayBoundary.check(op.method, op.path);
    final hc.Request request = hc.Request(op.method, uri)
      ..headers.addAll(<String, String>{
        'Authorization': 'Bearer $token',
        'Accept': 'text/event-stream',
        'Relay-Version': relayApiVersion,
        'Last-Event-ID': ?cursor,
      });
    final hc.StreamedResponse response;
    try {
      response = await http.client.send(request);
    } on Object {
      _fail(controller, const RelayRealtimeClosed('connect_failed'));
      return;
    }
    if (response.statusCode != 200) {
      final String body = await response.stream.bytesToString();
      String? code;
      try {
        final Object? decoded = jsonDecode(body);
        if (decoded is Map<String, Object?> && decoded['code'] is String) {
          code = decoded['code']! as String;
        }
      } on FormatException {
        code = null;
      }
      _fail(
        controller,
        relayClassifyClose(
          code ?? 'http_${response.statusCode}',
          retryAfter: parseRetryAfter(response.headers['retry-after']),
        ),
      );
      return;
    }
    if (controller.isClosed) return;
    controller.add(const RelayRealtimeOpened());
    String? event;
    String? id;
    final StringBuffer data = StringBuffer();
    _sub = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (String line) {
            if (line.isEmpty) {
              if (data.isNotEmpty) {
                _dispatch(controller, event, id, data.toString());
              }
              event = null;
              data.clear();
              return;
            }
            if (line.startsWith(':')) return;
            final int colon = line.indexOf(':');
            final String field = colon < 0 ? line : line.substring(0, colon);
            String value = colon < 0 ? '' : line.substring(colon + 1);
            if (value.startsWith(' ')) value = value.substring(1);
            switch (field) {
              case 'event':
                event = value;
              case 'data':
                if (data.isNotEmpty) data.write('\n');
                data.write(value);
              case 'id':
                id = value;
            }
          },
          onDone: () =>
              _fail(controller, const RelayRealtimeClosed('stream_ended')),
          onError: (Object _) =>
              _fail(controller, const RelayRealtimeClosed('stream_error')),
        );
  }

  void _dispatch(
    StreamController<RelayRealtimeFrame> controller,
    String? event,
    String? id,
    String data,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, Object?>) return;
    final Map<String, Object?> envelope = <String, Object?>{
      ...decoded,
      if (decoded['id'] == null && id != null) 'id': id,
    };
    if (event != null && envelope['t'] != event) return;
    if (!controller.isClosed) {
      controller.add(RelayRealtimeEnvelopeFrame(envelope));
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
  Future<void> refreshToken(String token) async {}

  @override
  Future<void> close() async {
    final StreamSubscription<String>? sub = _sub;
    _sub = null;
    await sub?.cancel();
    final StreamController<RelayRealtimeFrame>? c = _controller;
    _controller = null;
    if (c != null && !c.isClosed) unawaited(c.close());
  }
}
