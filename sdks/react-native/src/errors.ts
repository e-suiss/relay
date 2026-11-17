import { ERROR_CODES, RETRYABLE_DEFAULTS } from './generated/errors';

/** An RFC 9457 problem as Relay returns it. */
export interface Problem {
  readonly type?: string;
  readonly title?: string;
  readonly status?: number;
  readonly code?: string;
  readonly detail?: string;
  readonly [extension: string]: unknown;
}

export interface RelayErrorInit {
  readonly status: number | null;
  readonly code: string | null;
  readonly retryable: boolean;
  readonly requestId: string | null;
  readonly retryAfterMs: number | null;
  readonly problem: Problem | null;
}

/** Base class of every error the SDK raises. */
export class RelayError extends Error {
  readonly status: number | null;
  readonly code: string | null;
  readonly retryable: boolean;
  readonly requestId: string | null;
  readonly retryAfterMs: number | null;
  readonly problem: Problem | null;

  constructor(message: string, init: RelayErrorInit) {
    super(message);
    this.name = new.target.name;
    this.status = init.status;
    this.code = init.code;
    this.retryable = init.retryable;
    this.requestId = init.requestId;
    this.retryAfterMs = init.retryAfterMs;
    this.problem = init.problem;
  }
}

/** The subscriber token is missing, expired, invalid or lacks the scope. */
export class RelayAuthError extends RelayError {}

/** The request did not pass validation (400, 413, 415, 422). */
export class RelayValidationError extends RelayError {}

/** The resource does not exist for this subscriber (404). */
export class RelayNotFoundError extends RelayError {}

/** The resource changed concurrently (409 other than idempotency). */
export class RelayConflictError extends RelayError {}

/** An Idempotency-Key problem: missing, invalid, reused with another body, or still in progress. */
export class RelayIdempotencyError extends RelayError {}

/** A rate limit or quota stopped the request (429). */
export class RelayRateLimitError extends RelayError {}

/** Relay or an upstream failed (5xx). */
export class RelayServerError extends RelayError {}

/** The request never got an HTTP answer. */
export class RelayNetworkError extends RelayError {}

/** The SDK refused a call outside the subscriber boundary before any network traffic. */
export class RelayBoundaryError extends RelayError {}

/** Whether a status and error code may be retried, from the contract's error catalog. */
export function isRetryable(status: number, code: string | null): boolean {
  if (code !== null) {
    const known = ERROR_CODES[code];
    if (known) return known.retryable;
    const exact = RETRYABLE_DEFAULTS.find((entry) => entry.status === status && entry.code === code);
    if (exact) return exact.retryable;
  }
  const byStatus = RETRYABLE_DEFAULTS.find((entry) => entry.status === status && entry.code === null);
  if (byStatus) return byStatus.retryable;
  return status >= 500;
}

/** Parses a Retry-After value (delta seconds or HTTP date) into milliseconds from `now`. */
export function parseRetryAfter(value: string | null, now: number): number | null {
  if (value === null) return null;
  const trimmed = value.trim();
  if (/^\d+$/.test(trimmed)) return Number(trimmed) * 1000;
  const at = Date.parse(trimmed);
  if (Number.isNaN(at)) return null;
  return Math.max(0, at - now);
}

type ErrorClass = new (message: string, init: RelayErrorInit) => RelayError;

function classFor(status: number, code: string | null): ErrorClass {
  if (code?.startsWith('idempotency_key')) return RelayIdempotencyError;
  if (status === 401 || status === 403) return RelayAuthError;
  if (status === 404) return RelayNotFoundError;
  if (status === 409) return RelayConflictError;
  if (status === 429) return RelayRateLimitError;
  if (status >= 500) return RelayServerError;
  return RelayValidationError;
}

/** Builds the typed error of an HTTP problem answer. */
export function errorFromProblem(
  status: number,
  problem: Problem | null,
  requestId: string | null,
  retryAfterMs: number | null,
): RelayError {
  const code = typeof problem?.code === 'string' ? problem.code : null;
  const ErrorType = classFor(status, code);
  const message = problem?.title ?? `HTTP ${String(status)}`;
  const known = code !== null && ERROR_CODES[code] !== undefined;
  const retryable =
    !known && typeof problem?.retryable === 'boolean'
      ? problem.retryable
      : isRetryable(status, code);
  return new ErrorType(message, {
    status,
    code,
    retryable,
    requestId,
    retryAfterMs,
    problem,
  });
}

/** Builds the error of a request that failed before an HTTP answer. */
export function networkError(): RelayNetworkError {
  return new RelayNetworkError('network request failed', {
    status: null,
    code: null,
    retryable: true,
    requestId: null,
    retryAfterMs: null,
    problem: null,
  });
}

/** Builds the error of a call outside the subscriber boundary. */
export function boundaryError(method: string, path: string): RelayBoundaryError {
  return new RelayBoundaryError(`${method} ${path} is outside the subscriber boundary`, {
    status: null,
    code: 'sdk_boundary',
    retryable: false,
    requestId: null,
    retryAfterMs: null,
    problem: null,
  });
}
