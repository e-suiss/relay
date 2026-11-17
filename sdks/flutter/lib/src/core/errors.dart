import '../generated/error_catalog.dart';

/// Whether a failed request may be retried, from the error catalog.
bool relayRetryable(int status, String? code) {
  if (code != null) {
    final RelayErrorSpec? spec = relayErrorCatalog[code];
    if (spec != null) return spec.retryable;
    for (final RelayRetryDefault d in relayRetryDefaults) {
      if (d.status == status && d.code == code) return d.retryable;
    }
  }
  for (final RelayRetryDefault d in relayRetryDefaults) {
    if (d.status == status && d.code == null) return d.retryable;
  }
  return status >= 500;
}

/// A failed Relay request (RFC 9457 problem details).
class RelayError implements Exception {
  /// Creates an error.
  RelayError({
    required this.status,
    required this.code,
    required this.retryable,
    this.title,
    this.detail,
    this.requestId,
    this.retryAfter,
    this.problem = const <String, Object?>{},
  });

  /// Builds the matching error type from a response.
  factory RelayError.fromResponse(
    int status,
    Map<String, Object?> problem, {
    String? requestId,
    Duration? retryAfter,
  }) {
    final Object? rawCode = problem['code'];
    final String? code = rawCode is String ? rawCode : null;
    final Object? rawTitle = problem['title'];
    final Object? rawDetail = problem['detail'];
    final String? title = rawTitle is String ? rawTitle : null;
    final String? detail = rawDetail is String ? rawDetail : null;
    final Object? flag = problem['retryable'];
    final bool known = code != null && relayErrorCatalog.containsKey(code);
    final bool retryable =
        !known && flag is bool ? flag : relayRetryable(status, code);
    final String? family = code == null ? null : relayErrorCatalog[code]?.family;
    if (family == 'idempotency') {
      return RelayIdempotencyError(
        status: status,
        code: code,
        retryable: retryable,
        title: title,
        detail: detail,
        requestId: requestId,
        retryAfter: retryAfter,
        problem: problem,
      );
    }
    if (status == 401 || status == 403) {
      return RelayAuthError(
        status: status,
        code: code,
        retryable: retryable,
        title: title,
        detail: detail,
        requestId: requestId,
        retryAfter: retryAfter,
        problem: problem,
      );
    }
    if (status == 404) {
      return RelayNotFoundError(
        status: status,
        code: code,
        retryable: retryable,
        title: title,
        detail: detail,
        requestId: requestId,
        retryAfter: retryAfter,
        problem: problem,
      );
    }
    if (status == 409) {
      return RelayConflictError(
        status: status,
        code: code,
        retryable: retryable,
        title: title,
        detail: detail,
        requestId: requestId,
        retryAfter: retryAfter,
        problem: problem,
      );
    }
    if (status == 429) {
      return RelayRateLimitError(
        status: status,
        code: code,
        retryable: retryable,
        title: title,
        detail: detail,
        requestId: requestId,
        retryAfter: retryAfter,
        problem: problem,
      );
    }
    if (status >= 500) {
      return RelayServerError(
        status: status,
        code: code,
        retryable: retryable,
        title: title,
        detail: detail,
        requestId: requestId,
        retryAfter: retryAfter,
        problem: problem,
      );
    }
    return RelayValidationError(
      status: status,
      code: code,
      retryable: retryable,
      title: title,
      detail: detail,
      requestId: requestId,
      retryAfter: retryAfter,
      problem: problem,
    );
  }

  /// HTTP status; 0 when no response arrived.
  final int status;

  /// Error code from the catalog.
  final String? code;

  /// Whether the request may be retried.
  final bool retryable;

  /// Problem title.
  final String? title;

  /// Problem detail.
  final String? detail;

  /// The Request-Id of the response.
  final String? requestId;

  /// The server's Retry-After.
  final Duration? retryAfter;

  /// The whole problem body.
  final Map<String, Object?> problem;

  @override
  String toString() => 'RelayError($status, $code)';
}

/// Credentials were missing, invalid, expired or lacked a scope.
class RelayAuthError extends RelayError {
  /// Creates the error.
  RelayAuthError({
    required super.status,
    required super.code,
    required super.retryable,
    super.title,
    super.detail,
    super.requestId,
    super.retryAfter,
    super.problem,
  });
}

/// The request was malformed or failed validation.
class RelayValidationError extends RelayError {
  /// Creates the error.
  RelayValidationError({
    required super.status,
    required super.code,
    required super.retryable,
    super.title,
    super.detail,
    super.requestId,
    super.retryAfter,
    super.problem,
  });
}

/// The resource does not exist for this subscriber.
class RelayNotFoundError extends RelayError {
  /// Creates the error.
  RelayNotFoundError({
    required super.status,
    required super.code,
    required super.retryable,
    super.title,
    super.detail,
    super.requestId,
    super.retryAfter,
    super.problem,
  });
}

/// The resource changed; `problem['current']` may carry its state.
class RelayConflictError extends RelayError {
  /// Creates the error.
  RelayConflictError({
    required super.status,
    required super.code,
    required super.retryable,
    super.title,
    super.detail,
    super.requestId,
    super.retryAfter,
    super.problem,
  });
}

/// A rate limit or quota was hit.
class RelayRateLimitError extends RelayError {
  /// Creates the error.
  RelayRateLimitError({
    required super.status,
    required super.code,
    required super.retryable,
    super.title,
    super.detail,
    super.requestId,
    super.retryAfter,
    super.problem,
  });
}

/// The Idempotency-Key was missing, invalid, reused or still in progress.
class RelayIdempotencyError extends RelayError {
  /// Creates the error.
  RelayIdempotencyError({
    required super.status,
    required super.code,
    required super.retryable,
    super.title,
    super.detail,
    super.requestId,
    super.retryAfter,
    super.problem,
  });
}

/// The server failed.
class RelayServerError extends RelayError {
  /// Creates the error.
  RelayServerError({
    required super.status,
    required super.code,
    required super.retryable,
    super.title,
    super.detail,
    super.requestId,
    super.retryAfter,
    super.problem,
  });
}

/// No response arrived (network failure or timeout).
class RelayNetworkError extends RelayError {
  /// Creates the error.
  RelayNetworkError({required this.cause})
      : super(status: 0, code: null, retryable: true);

  /// The underlying failure.
  final Object cause;
}

/// The SDK refused a call outside the client boundary before any request.
class RelayBoundaryError extends RelayError {
  /// Creates the error.
  RelayBoundaryError(this.method, this.path)
      : super(status: 0, code: 'client_boundary', retryable: false);

  /// The refused method.
  final String method;

  /// The refused path.
  final String path;
}
