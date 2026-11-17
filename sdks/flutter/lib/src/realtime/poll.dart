import 'dart:async';

import '../core/errors.dart';
import '../core/http.dart';
import '../generated/models.dart';
import '../generated/operations.dart';
import 'transport.dart';

// IN-23
/// The long-poll transport, the last fallback of the inbox stream.
class RelayPollTransport implements RelayRealtimeTransport {
  /// Creates the transport.
  RelayPollTransport({required this.http});

  /// The HTTP core.
  final RelayHttp http;

  bool _open = false;
  StreamController<RelayRealtimeFrame>? _controller;

  @override
  String get name => 'long_poll';

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
      _open = true;
      unawaited(_run(controller, cursor));
    };
    controller.onCancel = close;
    return controller.stream;
  }

  Future<void> _run(
    StreamController<RelayRealtimeFrame> controller,
    String? start,
  ) async {
    String? cursor = start;
    bool opened = false;
    while (_open && !controller.isClosed) {
      final RealtimePoll poll;
      try {
        final RelayResponse response = await http.send(
          RelayOperation.pollRealtimeEvents,
          query: <String, String?>{'cursor': cursor},
          retries: 0,
        );
        poll = RealtimePoll.fromJson(response.json);
      } on RelayError catch (error) {
        if (!controller.isClosed) {
          controller.addError(
            relayClassifyClose(
              error.code ?? 'http_${error.status}',
              retryAfter: error.retryAfter,
            ),
          );
          unawaited(controller.close());
        }
        return;
      }
      if (!_open || controller.isClosed) return;
      if (!opened) {
        opened = true;
        controller.add(const RelayRealtimeOpened());
      }
      for (final RealtimeEnvelope e in poll.events) {
        controller.add(RelayRealtimeEnvelopeFrame(e.toJson()));
      }
      cursor = poll.cursor;
      controller.add(RelayRealtimeCursorFrame(poll.cursor));
    }
  }

  @override
  Future<void> refreshToken(String token) async {}

  @override
  Future<void> close() async {
    _open = false;
    final StreamController<RelayRealtimeFrame>? c = _controller;
    _controller = null;
    if (c != null && !c.isClosed) unawaited(c.close());
  }
}
