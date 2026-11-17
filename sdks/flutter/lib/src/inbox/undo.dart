import 'dart:async';

// IN-15
/// Holds an action for a short window before it is sent; undo cancels it without any request.
class RelayUndoBuffer {
  /// Creates the buffer.
  RelayUndoBuffer({this.window = const Duration(seconds: 5)});

  /// How long an action can be undone.
  final Duration window;

  final Map<String, (Timer, Future<void> Function())> _pending =
      <String, (Timer, Future<void> Function())>{};

  /// Whether an action is waiting for a key.
  bool isPending(String key) => _pending.containsKey(key);

  /// Schedules an action; a pending one for the same key is committed first.
  void schedule(String key, Future<void> Function() commit) {
    final (Timer, Future<void> Function())? old = _pending.remove(key);
    if (old != null) {
      old.$1.cancel();
      unawaited(old.$2());
    }
    final Timer timer = Timer(window, () {
      final (Timer, Future<void> Function())? entry = _pending.remove(key);
      if (entry != null) unawaited(entry.$2());
    });
    _pending[key] = (timer, commit);
  }

  /// Cancels a pending action; returns whether one was pending.
  bool undo(String key) {
    final (Timer, Future<void> Function())? entry = _pending.remove(key);
    entry?.$1.cancel();
    return entry != null;
  }

  /// Sends every pending action now.
  Future<void> flush() async {
    final List<(Timer, Future<void> Function())> entries = _pending.values.toList();
    _pending.clear();
    for (final (Timer, Future<void> Function()) e in entries) {
      e.$1.cancel();
      await e.$2();
    }
  }
}
