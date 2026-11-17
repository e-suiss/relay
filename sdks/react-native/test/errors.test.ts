import { describe, expect, it } from 'vitest';
import {
  errorFromProblem,
  isRetryable,
  parseRetryAfter,
  RelayAuthError,
  RelayConflictError,
  RelayIdempotencyError,
  RelayNotFoundError,
  RelayRateLimitError,
  RelayServerError,
  RelayValidationError,
} from '../src/errors';
import { readYaml } from './helpers';

interface Catalog {
  retryable_defaults: { status: number; code?: string; retryable: boolean }[];
  codes: { code: string; status: number; retryable: boolean }[];
}

const catalog = readYaml<Catalog>('contracts/errors.yaml');

describe('X-29 X-48 error to retryable mapping from contracts/errors.yaml', () => {
  it('X-48 maps every catalogued code to its retryable flag', () => {
    expect(catalog.codes.length).toBeGreaterThan(100);
    for (const entry of catalog.codes) {
      expect(isRetryable(entry.status, entry.code), entry.code).toBe(entry.retryable);
    }
  });

  it('X-48 falls back to the status defaults for an unknown code', () => {
    for (const entry of catalog.retryable_defaults.filter((item) => item.code === undefined)) {
      expect(isRetryable(entry.status, 'not_a_catalogued_code')).toBe(entry.retryable);
    }
    expect(isRetryable(502, null)).toBe(true);
    expect(isRetryable(422, null)).toBe(false);
  });

  it('X-29 parses Retry-After as seconds or an HTTP date', () => {
    const now = Date.parse('2026-11-18T09:00:00Z');
    expect(parseRetryAfter('3', now)).toBe(3000);
    expect(parseRetryAfter('Wed, 18 Nov 2026 09:00:10 GMT', now)).toBe(10_000);
    expect(parseRetryAfter('soon', now)).toBeNull();
    expect(parseRetryAfter(null, now)).toBeNull();
  });

  it('X-29 builds the typed error hierarchy', () => {
    const cases: [number, string, unknown][] = [
      [401, 'auth_expired_token', RelayAuthError],
      [403, 'auth_insufficient_scope', RelayAuthError],
      [404, 'inbox_item_not_found', RelayNotFoundError],
      [409, 'inbox_item_conflict', RelayConflictError],
      [409, 'idempotency_key_in_progress', RelayIdempotencyError],
      [422, 'idempotency_key_reuse', RelayIdempotencyError],
      [422, 'validation_failed', RelayValidationError],
      [429, 'rate_limited', RelayRateLimitError],
      [503, 'service_unavailable', RelayServerError],
    ];
    for (const [status, code, type] of cases) {
      const error = errorFromProblem(status, { code, title: code }, 'req_1', null);
      expect(error, code).toBeInstanceOf(type);
      expect(error.code).toBe(code);
      expect(error.requestId).toBe('req_1');
    }
  });

  it('X-29 uses the problem retryable member only for codes the catalog does not know', () => {
    expect(
      errorFromProblem(500, { code: 'future_code', retryable: false }, null, null).retryable,
    ).toBe(false);
    expect(
      errorFromProblem(422, { code: 'validation_failed', retryable: true }, null, null).retryable,
    ).toBe(false);
  });
});
