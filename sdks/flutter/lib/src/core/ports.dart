import 'dart:math';

/// The time source of the SDK.
abstract interface class RelayClock {
  /// The current UTC time.
  DateTime now();
}

/// The system clock.
class SystemRelayClock implements RelayClock {
  /// Creates the system clock.
  const SystemRelayClock();

  @override
  DateTime now() => DateTime.now().toUtc();
}

/// The randomness source of the SDK.
abstract interface class RelayRandom {
  /// A double in [0, 1).
  double nextDouble();

  /// An integer in [0, max).
  int nextInt(int max);
}

/// A cryptographically secure random source.
class SecureRelayRandom implements RelayRandom {
  /// Creates a secure random source.
  SecureRelayRandom() : _random = Random.secure();

  final Random _random;

  @override
  double nextDouble() => _random.nextDouble();

  @override
  int nextInt(int max) => _random.nextInt(max);
}

/// Waits for a duration; injectable so tests run without real time.
typedef RelayDelay = Future<void> Function(Duration duration);

/// The default delay.
Future<void> relayDefaultDelay(Duration duration) =>
    Future<void>.delayed(duration);

/// Durable key-value storage owned by the host app.
abstract interface class RelayKeyValueStore {
  /// Reads a value.
  Future<String?> read(String key);

  /// Writes a value.
  Future<void> write(String key, String value);

  /// Removes a value.
  Future<void> remove(String key);
}

/// An in-memory store.
class MemoryRelayKeyValueStore implements RelayKeyValueStore {
  /// Creates an empty in-memory store.
  MemoryRelayKeyValueStore();

  /// The stored values.
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

/// Log levels of the SDK.
enum RelayLogLevel {
  /// Diagnostic detail.
  debug,

  /// Normal operation.
  info,

  /// Recoverable problems.
  warning,

  /// Failures.
  error,
}

/// Receives the SDK's log events; never receives tokens or device status values.
abstract interface class RelayLogger {
  /// Logs one event with non-personal fields.
  void log(
    RelayLogLevel level,
    String event, [
    Map<String, Object?> fields = const <String, Object?>{},
  ]);
}

/// A logger that drops everything.
class SilentRelayLogger implements RelayLogger {
  /// Creates the silent logger.
  const SilentRelayLogger();

  @override
  void log(
    RelayLogLevel level,
    String event, [
    Map<String, Object?> fields = const <String, Object?>{},
  ]) {}
}

/// A random UUID v4 for idempotency keys.
String relayUuid(RelayRandom random) {
  final List<int> bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final String hex = bytes
      .map((int b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Full-jitter backoff: a random delay between zero and min(cap, base * 2^attempt).
Duration relayBackoff(
  int attempt,
  RelayRandom random, {
  Duration base = const Duration(seconds: 1),
  Duration cap = const Duration(seconds: 60),
}) {
  final int exp = attempt.clamp(0, 30);
  final int ceiling = min(cap.inMilliseconds, base.inMilliseconds * (1 << exp));
  return Duration(milliseconds: (random.nextDouble() * ceiling).floor());
}
