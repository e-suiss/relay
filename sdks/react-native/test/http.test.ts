import { describe, expect, it } from 'vitest';
import { RelayBoundaryError, RelayValidationError } from '../src/errors';
import { API_VERSION } from '../src/ports';
import { json, problem, testHttp } from './helpers';

const prefs = { object: 'subscriber_preferences', cells: [] };

describe('X-29 HTTP core', () => {
  it('X-29 sends the subscriber token, Relay-Version and an Idempotency-Key on mutations', async () => {
    const { http, requests } = testHttp(() => json(200, prefs));
    await http.request({ method: 'PATCH', path: '/v1/subscriber/preferences', body: { profile: {} } });
    await http.request({ method: 'GET', path: '/v1/subscriber/preferences' });
    const [patch, get] = requests;
    expect(patch?.headers.Authorization).toBe('Bearer subscriber-token-1');
    expect(patch?.headers['Relay-Version']).toBe(API_VERSION);
    expect(patch?.headers['Idempotency-Key']).toMatch(/^[0-9a-f-]{36}$/);
    expect(patch?.headers['Content-Type']).toBe('application/json');
    expect(get?.headers['Idempotency-Key']).toBeUndefined();
  });

  it('X-29 keeps the same Idempotency-Key on every retry of a retryable error', async () => {
    let calls = 0;
    const { http, requests } = testHttp(() => {
      calls += 1;
      return calls < 3 ? problem(503, 'service_unavailable', { retryable: true }) : json(200, prefs);
    });
    await http.request({ method: 'PATCH', path: '/v1/subscriber/preferences', body: { profile: {} } });
    expect(requests).toHaveLength(3);
    const keys = new Set(requests.map((request) => request.headers['Idempotency-Key']));
    expect(keys.size).toBe(1);
  });

  it('X-29 waits for Retry-After before retrying', async () => {
    let calls = 0;
    const { http, clock } = testHttp(() => {
      calls += 1;
      return calls === 1 ? problem(429, 'rate_limited', {}, { 'Retry-After': '7' }) : json(200, prefs);
    });
    await http.request({ method: 'GET', path: '/v1/subscriber/preferences' });
    expect((clock as unknown as { delays: number[] }).delays).toEqual([7000]);
  });

  it('X-29 uses full-jitter backoff when no Retry-After is given', async () => {
    let calls = 0;
    const { http, clock } = testHttp(() => {
      calls += 1;
      return calls < 4 ? problem(500, 'internal_error') : json(200, prefs);
    });
    await http.request({ method: 'GET', path: '/v1/subscriber/preferences' });
    expect((clock as unknown as { delays: number[] }).delays).toEqual([500, 1000, 2000]);
  });

  it('X-29 never retries a non-retryable error', async () => {
    const { http, requests } = testHttp(() => problem(422, 'validation_failed'));
    await expect(
      http.request({ method: 'PATCH', path: '/v1/subscriber/preferences', body: {} }),
    ).rejects.toBeInstanceOf(RelayValidationError);
    expect(requests).toHaveLength(1);
  });

  it('X-29 retries a network failure with the same key and gives up after three retries', async () => {
    const { http, requests } = testHttp(() => 'network');
    await expect(
      http.request({ method: 'POST', path: '/v1/subscriber/inbox/read_all', body: {} }),
    ).rejects.toMatchObject({ retryable: true, status: null });
    expect(requests).toHaveLength(4);
    expect(new Set(requests.map((request) => request.headers['Idempotency-Key'])).size).toBe(1);
  });

  it('X-31 asks the host for a fresh token once after auth_expired_token', async () => {
    let calls = 0;
    const { http, requests, tokenCalls } = testHttp(() => {
      calls += 1;
      return calls === 1 ? problem(401, 'auth_expired_token') : json(200, prefs);
    });
    await http.request({ method: 'GET', path: '/v1/subscriber/preferences' });
    expect(tokenCalls).toEqual([false, true]);
    expect(requests[1]?.headers.Authorization).toBe('Bearer subscriber-token-2');
  });

  it('X-31 refuses an operation outside the subscriber boundary before any request', async () => {
    const { http, requests } = testHttp(() => json(200, {}));
    await expect(
      http.request({ method: 'POST', path: '/v1/events' as never, body: {} }),
    ).rejects.toBeInstanceOf(RelayBoundaryError);
    expect(requests).toHaveLength(0);
  });

  it('X-29 encodes path parameters and drops undefined query values', () => {
    const { http } = testHttp(() => json(200, {}));
    expect(
      http.url('/v1/subscriber/inbox/items/{item_id}', { item_id: 'inb_a/b' }, { a: undefined, b: 2 }),
    ).toBe('https://relay.example.com/v1/subscriber/inbox/items/inb_a%2Fb?b=2');
  });
});
