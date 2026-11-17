import '../core/errors.dart';
import '../core/http.dart';
import '../core/ports.dart';
import '../generated/models.dart';
import '../generated/operations.dart';

/// The device status signals of dictionary v1.
enum RelayDeviceSignal {
  /// A wearable is worn.
  worn('worn'),

  /// The screen is locked.
  locked('locked'),

  /// Headphones are connected.
  headphones('headphones'),

  /// A focus mode is on.
  focus('focus'),

  /// A natural break.
  breakPoint('break');

  const RelayDeviceSignal(this.wire);

  /// The dictionary key.
  final String wire;
}

// IN-47
// IN-48
// IN-53
/// Writes this device's short-lived status signals: only changed keys, at most one write a second, never stored, queued or logged.
class RelayDeviceStatusWriter {
  /// Creates the writer.
  RelayDeviceStatusWriter({
    required this.http,
    required this.deviceId,
    RelayClock? clock,
    RelayDelay? delay,
    RelayLogger? logger,
  }) : clock = clock ?? const SystemRelayClock(),
       delay = delay ?? relayDefaultDelay,
       logger = logger ?? const SilentRelayLogger();

  /// The HTTP core.
  final RelayHttp http;

  /// The registered device id.
  final Future<String?> Function() deviceId;

  /// The clock.
  final RelayClock clock;

  /// Waits for the next write slot.
  final RelayDelay delay;

  /// The logger; it never receives a signal value.
  final RelayLogger logger;

  /// The default time to live.
  static const Duration defaultTtl = Duration(minutes: 5);

  /// The longest time to live Relay keeps.
  static const Duration maxTtl = Duration(minutes: 15);

  /// The shortest time to live.
  static const Duration minTtl = Duration(seconds: 1);

  final Map<RelayDeviceSignal, bool> _sent = <RelayDeviceSignal, bool>{};
  final Map<RelayDeviceSignal, bool> _pending = <RelayDeviceSignal, bool>{};
  Duration? _pendingTtl;
  DateTime? _lastWrite;
  Future<void>? _running;

  /// Clamps a time to live to the dictionary bounds.
  static Duration clampTtl(Duration? ttl) {
    final Duration t = ttl ?? defaultTtl;
    if (t < minTtl) return minTtl;
    if (t > maxTtl) return maxTtl;
    return t;
  }

  /// Sets signals; unchanged ones are not sent.
  Future<void> set(Map<RelayDeviceSignal, bool> signals, {Duration? ttl}) {
    signals.forEach((RelayDeviceSignal k, bool v) {
      if (_sent[k] == v) {
        _pending.remove(k);
      } else {
        _pending[k] = v;
      }
    });
    _pendingTtl = ttl ?? _pendingTtl;
    return _running ??= _drain().whenComplete(() {
      _running = null;
    });
  }

  Future<void> _drain() async {
    while (_pending.isNotEmpty) {
      final DateTime? last = _lastWrite;
      if (last != null) {
        final Duration since = clock.now().difference(last);
        if (since < const Duration(seconds: 1)) {
          await delay(const Duration(seconds: 1) - since);
        }
      }
      final String? id = await deviceId();
      if (id == null) {
        _pending.clear();
        return;
      }
      final Map<RelayDeviceSignal, bool> batch =
          Map<RelayDeviceSignal, bool>.of(_pending);
      final Duration ttl = clampTtl(_pendingTtl);
      _pending.clear();
      _lastWrite = clock.now();
      try {
        await http.send(
          RelayOperation.updateMyDeviceStatus,
          pathParams: <String, String>{'device_id': id},
          body: DeviceStatusWrite(
            version: 'v1',
            signals: DeviceStatusWriteSignals(
              worn: batch[RelayDeviceSignal.worn],
              locked: batch[RelayDeviceSignal.locked],
              headphones: batch[RelayDeviceSignal.headphones],
              focus: batch[RelayDeviceSignal.focus],
              breakValue: batch[RelayDeviceSignal.breakPoint],
            ),
            ttl: 'PT${ttl.inSeconds}S',
          ).toJson(),
          retries: 0,
        );
        _sent.addAll(batch);
        logger.log(RelayLogLevel.debug, 'device_status.written');
      } on RelayError catch (error) {
        logger.log(
          RelayLogLevel.debug,
          'device_status.failed',
          <String, Object?>{'status': error.status},
        );
        if (error is RelayRateLimitError) {
          batch.forEach((RelayDeviceSignal k, bool v) {
            _pending.putIfAbsent(k, () => v);
          });
        }
      }
    }
  }
}
