export type HttpMethod = 'GET' | 'POST' | 'PATCH' | 'DELETE';

export interface AllowedOperation {
  readonly method: HttpMethod;
  readonly path: string;
  readonly idempotencyKey: boolean;
}

// X-31
// X-32
export const ALLOWED_OPERATIONS: readonly AllowedOperation[] = [
  { method: 'GET', path: '/v1/subscriber/preferences', idempotencyKey: false },
  { method: 'PATCH', path: '/v1/subscriber/preferences', idempotencyKey: true },
  { method: 'POST', path: '/v1/subscriber/devices', idempotencyKey: true },
  { method: 'DELETE', path: '/v1/subscriber/devices/{device_id}', idempotencyKey: true },
  { method: 'GET', path: '/v1/subscriber/devices/status', idempotencyKey: false },
  { method: 'PATCH', path: '/v1/subscriber/devices/{device_id}/status', idempotencyKey: false },
  { method: 'POST', path: '/v1/subscriber/push_receipts', idempotencyKey: true },
  { method: 'GET', path: '/v1/subscriber/inbox/items', idempotencyKey: false },
  { method: 'GET', path: '/v1/subscriber/inbox/items/{item_id}', idempotencyKey: false },
  { method: 'POST', path: '/v1/subscriber/inbox/items/{item_id}/intents', idempotencyKey: true },
  { method: 'GET', path: '/v1/subscriber/inbox/counters', idempotencyKey: false },
  { method: 'GET', path: '/v1/subscriber/inbox/changes', idempotencyKey: false },
  { method: 'POST', path: '/v1/subscriber/inbox/read_all', idempotencyKey: true },
  { method: 'POST', path: '/v1/subscriber/inbox/counters/inconsistency', idempotencyKey: false },
  { method: 'GET', path: '/v1/realtime/events', idempotencyKey: false },
  { method: 'GET', path: '/v1/realtime/poll', idempotencyKey: false },
];

export const REALTIME_WEBSOCKET_PATH = '/v1/realtime/websocket';

/** The allowed operation for a method and path template, or `undefined` when the subscriber boundary forbids it. */
export function allowedOperation(method: string, path: string): AllowedOperation | undefined {
  return ALLOWED_OPERATIONS.find(
    (operation) => operation.method === method && operation.path === path,
  );
}
