import 'dart:io';

import 'phoenix.dart';

class _IoWebSocket implements RelayWebSocket {
  _IoWebSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<String> get messages =>
      _socket.where((dynamic m) => m is String).map((dynamic m) => m as String);

  @override
  void send(String data) => _socket.add(data);

  @override
  Future<void> close() => _socket.close();

  @override
  int? get closeCode => _socket.closeCode;

  @override
  String? get closeReason => _socket.closeReason;
}

/// Opens a WebSocket with dart:io.
Future<RelayWebSocket> relayIoWebSocketConnector(
  Uri uri,
  List<String> protocols,
) async {
  final WebSocket socket = await WebSocket.connect(
    uri.toString(),
    protocols: protocols,
  );
  socket.pingInterval = const Duration(seconds: 15);
  return _IoWebSocket(socket);
}
