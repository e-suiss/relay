import 'dart:convert';

import 'package:http/http.dart' as http;

import '../generated/operations.dart';
import 'boundary.dart';
import 'errors.dart';
import 'ports.dart';

/// A Relay subscriber token supplied by the host app.
class SubscriberToken {
  /// Creates a token.
  const SubscriberToken(this.token, {this.expiresAt});

  /// The bearer token.
  final String token;

  /// When it expires, when known.
  final DateTime? expiresAt;
}

/// Supplies subscriber tokens; the host app obtains them, the SDK never holds secret credentials.
typedef SubscriberTokenProvider = Future<SubscriberToken> Function({
  required bool forceRefresh,
});

/// A decoded response.
class RelayResponse {
  /// Creates a response.
  const RelayResponse(this.status, this.body, this.headers);

  /// HTTP status.
  final int status;

  /// Decoded JSON body, or null when empty.
  final Object? body;

  /// Response headers.
  final Map<String, String> headers;

  /// The body as a JSON object.
  Map<String, Object?> get json => body! as Map<String, Object?>;
}

/// The HTTP core: auth, versioning, idempotency, retries and the client boundary.
class RelayHttp {
  /// Creates the core.
  RelayHttp({
    required Uri baseUrl,
    required this.tokenProvider,
    http.Client? client,
    RelayRandom? random,
    RelayDelay? delay,
    RelayLogger? logger,
    RelayClock? clock,
    this.maxRetries = 3,
  }) : baseUrl = _checkBase(baseUrl),
       clock = clock ?? const SystemRelayClock(),
       client = client ?? http.Client(),
       random = random ?? SecureRelayRandom(),
       delay = delay ?? relayDefaultDelay,
       logger = logger ?? const SilentRelayLogger();

  /// The region base URL.
  final Uri baseUrl;

  /// The host's token provider.
  final SubscriberTokenProvider tokenProvider;

  /// The HTTP client.
  final http.Client client;

  /// Randomness for keys and jitter.
  final RelayRandom random;

  /// Waits between retries.
  final RelayDelay delay;

  /// The logger.
  final RelayLogger logger;

  /// The clock.
  final RelayClock clock;

  /// Retries after the first attempt.
  final int maxRetries;

  SubscriberToken? _token;

  static Uri _checkBase(Uri uri) {
    final bool loopback = uri.host == 'localhost' || uri.host == '127.0.0.1';
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) {
      throw ArgumentError.value(uri, 'baseUrl', 'must be https');
    }
    return uri;
  }

  /// The current token, asking the provider when none is held.
  Future<SubscriberToken> token({bool forceRefresh = false}) async {
    final SubscriberToken? held = _token;
    final DateTime? expiresAt = held?.expiresAt;
    final bool expiring =
        expiresAt != null &&
        !clock.now().isBefore(expiresAt.subtract(const Duration(seconds: 30)));
    if (!forceRefresh && held != null && !expiring) return held;
    final SubscriberToken fresh = await tokenProvider(
      forceRefresh: forceRefresh,
    );
    _token = fresh;
    return fresh;
  }

  /// Drops the held token.
  void clearToken() {
    _token = null;
  }

  /// A new idempotency key.
  String newIdempotencyKey() => relayUuid(random);

  /// Builds the URL of an operation.
  Uri url(
    String path, {
    Map<String, String> pathParams = const <String, String>{},
    Map<String, String?> query = const <String, String?>{},
  }) {
    String resolved = path;
    pathParams.forEach((String k, String v) {
      resolved = resolved.replaceAll('{$k}', Uri.encodeComponent(v));
    });
    final Map<String, String> q = <String, String>{
      for (final MapEntry<String, String?> e in query.entries)
        if (e.value != null) e.key: e.value!,
    };
    final String prefix = baseUrl.path.endsWith('/')
        ? baseUrl.path.substring(0, baseUrl.path.length - 1)
        : baseUrl.path;
    return baseUrl.replace(
      path: '$prefix$resolved',
      queryParameters: q.isEmpty ? null : q,
    );
  }

  /// Sends one operation, retrying only retryable failures with the same Idempotency-Key.
  Future<RelayResponse> send(
    RelayOperation op, {
    Map<String, String> pathParams = const <String, String>{},
    Map<String, String?> query = const <String, String?>{},
    Object? body,
    String? idempotencyKey,
    int? retries,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final Uri uri = url(op.path, pathParams: pathParams, query: query);
    RelayBoundary.check(op.method, uri.path.substring(_basePrefixLength));
    final String? key = op.idempotencyRequired
        ? (idempotencyKey ?? newIdempotencyKey())
        : null;
    final int limit = retries ?? maxRetries;
    bool refreshed = false;
    int attempt = 0;
    while (true) {
      final SubscriberToken tok = await token();
      final http.Request request = http.Request(op.method, uri)
        ..headers.addAll(<String, String>{
          'Authorization': 'Bearer ${tok.token}',
          'Relay-Version': relayApiVersion,
          'Accept': 'application/json',
          ...headers,
          'Idempotency-Key': ?key,
        });
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      final http.Response response;
      try {
        response = await http.Response.fromStream(await client.send(request));
      } on Exception catch (cause) {
        if (attempt < limit) {
          await delay(relayBackoff(attempt, random));
          attempt++;
          continue;
        }
        throw RelayNetworkError(cause: cause);
      }
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final String text = response.body;
        return RelayResponse(
          response.statusCode,
          text.isEmpty ? null : jsonDecode(text),
          response.headers,
        );
      }
      final RelayError error = _error(response);
      if (response.statusCode == 401 &&
          !refreshed &&
          (error.code == 'auth_expired_token' ||
              error.code == 'auth_invalid_token')) {
        refreshed = true;
        await token(forceRefresh: true);
        continue;
      }
      if (error.retryable && attempt < limit) {
        await delay(error.retryAfter ?? relayBackoff(attempt, random));
        attempt++;
        continue;
      }
      logger.log(RelayLogLevel.warning, 'request.failed', <String, Object?>{
        'operation': op.name,
        'status': error.status,
        'code': error.code,
      });
      throw error;
    }
  }

  int get _basePrefixLength {
    final String p = baseUrl.path;
    return p.endsWith('/') ? p.length - 1 : p.length;
  }

  RelayError _error(http.Response response) {
    Map<String, Object?> problem = const <String, Object?>{};
    try {
      final Object? decoded = jsonDecode(response.body);
      if (decoded is Map<String, Object?>) problem = decoded;
    } on FormatException {
      problem = const <String, Object?>{};
    }
    return RelayError.fromResponse(
      response.statusCode,
      problem,
      requestId: response.headers['request-id'],
      retryAfter: parseRetryAfter(response.headers['retry-after']),
    );
  }
}

const List<String> _months = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Parses a Retry-After header: delay seconds or an HTTP date.
Duration? parseRetryAfter(String? value, {DateTime? now}) {
  if (value == null) return null;
  final String v = value.trim();
  final int? seconds = int.tryParse(v);
  if (seconds != null) return seconds < 0 ? null : Duration(seconds: seconds);
  final RegExpMatch? m = RegExp(
    r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
  ).firstMatch(v);
  if (m == null) return null;
  final int month = _months.indexOf(m.group(2)!) + 1;
  if (month == 0) return null;
  final DateTime at = DateTime.utc(
    int.parse(m.group(3)!),
    month,
    int.parse(m.group(1)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6)!),
  );
  final Duration d = at.difference(now ?? DateTime.now().toUtc());
  return d.isNegative ? Duration.zero : d;
}
