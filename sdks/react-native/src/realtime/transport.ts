import type { RealtimeEnvelope } from '../types';

export type TransportName = 'websocket' | 'sse' | 'poll';

export type CloseReason = 'closed' | 'error' | 'auth_expired' | 'overloaded' | 'fatal';

export interface CloseInfo {
  readonly reason: CloseReason;
  readonly detail: string | null;
  readonly retryAfterMs: number | null;
}

export interface TransportHandlers {
  onOpen(): void;
  onEnvelope(envelope: RealtimeEnvelope): void;
  onClose(info: CloseInfo): void;
}

export interface ConnectOptions {
  readonly token: string;
  readonly cursor: string | null;
  readonly deviceId: string | null;
}

/** One realtime transport of the inbox stream; all three carry the same envelopes (IN-23). */
export interface RealtimeTransport {
  readonly name: TransportName;
  connect(options: ConnectOptions, handlers: TransportHandlers): void;
  close(): void;
  refreshToken?(token: string): void;
}

const FATAL = new Set([
  'auth_subscriber_suspended',
  'auth_tenant_suspended',
  'realtime_origin_not_allowed',
  'connection_limit',
  'auth_insufficient_scope',
]);
const AUTH = new Set(['auth_expired_token', 'auth_invalid_token', 'auth_missing_credentials']);

// IN-33
// IN-52
// IN-58
/** Maps a server close or refusal (WebSocket close code and reason, or HTTP status and error code) to what the client does next. */
export function classifyClose(
  code: number | null,
  detail: string | null,
  retryAfterMs: number | null = null,
): CloseInfo {
  const reason = detail ?? '';
  if (AUTH.has(reason) || code === 401)
    return { reason: 'auth_expired', detail, retryAfterMs: null };
  if (FATAL.has(reason) || code === 403) return { reason: 'fatal', detail, retryAfterMs: null };
  if (code === 1013 || code === 503 || code === 429) {
    const match = /retry-after=(\d+)/.exec(reason);
    const ms = match?.[1] ? Number(match[1]) * 1000 : retryAfterMs;
    return { reason: 'overloaded', detail, retryAfterMs: ms };
  }
  return { reason: 'error', detail, retryAfterMs: null };
}

const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

/** Accepts a value as an envelope when it has the `{t, v, ts, d, counters}` shape. */
export function asEnvelope(value: unknown): RealtimeEnvelope | null {
  if (!isObject(value)) return null;
  if (typeof value.t !== 'string' || typeof value.v !== 'number' || typeof value.ts !== 'string') {
    return null;
  }
  if (!isObject(value.d) || !isObject(value.counters)) return null;
  return value as unknown as RealtimeEnvelope;
}
