/// A frame a realtime transport yields.
sealed class RelayRealtimeFrame {
  const RelayRealtimeFrame();
}

/// The transport is connected and authorised.
class RelayRealtimeOpened extends RelayRealtimeFrame {
  /// Creates the frame.
  const RelayRealtimeOpened();
}

/// One envelope `{t, v, ts, d, counters, id}`.
class RelayRealtimeEnvelopeFrame extends RelayRealtimeFrame {
  /// Creates the frame.
  const RelayRealtimeEnvelopeFrame(this.envelope);

  /// The envelope.
  final Map<String, Object?> envelope;
}

/// The stream position moved without an envelope (long-poll head cursor).
class RelayRealtimeCursorFrame extends RelayRealtimeFrame {
  /// Creates the frame.
  const RelayRealtimeCursorFrame(this.cursor);

  /// The cursor.
  final String cursor;
}

/// Why a transport closed.
class RelayRealtimeClosed implements Exception {
  /// Creates a close reason.
  const RelayRealtimeClosed(
    this.reason, {
    this.retryAfter,
    this.fatal = false,
    this.refreshToken = false,
  });

  /// The reason.
  final String reason;

  /// The server's wait before reconnecting.
  final Duration? retryAfter;

  /// Whether reconnecting is pointless (suspension, origin, connection limit).
  final bool fatal;

  /// Whether a fresh token is needed.
  final bool refreshToken;

  @override
  String toString() => 'RelayRealtimeClosed($reason)';
}

/// Classifies a close reason of the realtime surface.
RelayRealtimeClosed relayClassifyClose(String? reason, {Duration? retryAfter}) {
  switch (reason) {
    case 'auth_expired_token':
    case 'auth_invalid_token':
      return RelayRealtimeClosed(reason!, refreshToken: true);
    case 'auth_subscriber_suspended':
    case 'auth_tenant_suspended':
    case 'realtime_origin_not_allowed':
    case 'connection_limit':
    case 'auth_insufficient_scope':
      return RelayRealtimeClosed(reason!, fatal: true);
  }
  final RegExpMatch? m = RegExp(r'^retry-after=(\d+)$').firstMatch(reason ?? '');
  if (m != null) {
    return RelayRealtimeClosed(
      'overloaded',
      retryAfter: Duration(seconds: int.parse(m.group(1)!)),
    );
  }
  return RelayRealtimeClosed(reason ?? 'closed', retryAfter: retryAfter);
}

/// One realtime transport of the inbox stream.
abstract interface class RelayRealtimeTransport {
  /// The transport name.
  String get name;

  /// Opens the stream; errors are [RelayRealtimeClosed].
  Stream<RelayRealtimeFrame> open({
    required String token,
    String? cursor,
    String? deviceId,
  });

  /// Sends a fresh token when the transport supports it.
  Future<void> refreshToken(String token);

  /// Closes the transport.
  Future<void> close();
}
