enum RelayOperation {
  getMyPreferences(
    'GET',
    '/v1/subscriber/preferences',
    idempotencyRequired: false,
    scopes: <String>['preferences'],
  ),
  updateMyPreferences(
    'PATCH',
    '/v1/subscriber/preferences',
    idempotencyRequired: true,
    scopes: <String>['preferences'],
  ),
  listMyConsents(
    'GET',
    '/v1/subscriber/consents',
    idempotencyRequired: false,
    scopes: <String>['preferences'],
  ),
  getMyPushContent(
    'GET',
    '/v1/subscriber/push_content/{delivery_id}',
    idempotencyRequired: false,
    scopes: <String>['inbox:read'],
  ),
  registerMyDevice(
    'POST',
    '/v1/subscriber/devices',
    idempotencyRequired: true,
    scopes: <String>['devices:write'],
  ),
  deleteMyDevice(
    'DELETE',
    '/v1/subscriber/devices/{device_id}',
    idempotencyRequired: true,
    scopes: <String>['devices:write'],
  ),
  getMyDeviceStatus(
    'GET',
    '/v1/subscriber/devices/status',
    idempotencyRequired: false,
    scopes: <String>['inbox:read', 'presence:write'],
  ),
  updateMyDeviceStatus(
    'PATCH',
    '/v1/subscriber/devices/{device_id}/status',
    idempotencyRequired: false,
    scopes: <String>['presence:write'],
  ),
  recordMyPushReceipt(
    'POST',
    '/v1/subscriber/push_receipts',
    idempotencyRequired: true,
    scopes: <String>['devices:write'],
  ),
  streamRealtimeEvents(
    'GET',
    '/v1/realtime/events',
    idempotencyRequired: false,
    scopes: <String>['inbox:read'],
  ),
  pollRealtimeEvents(
    'GET',
    '/v1/realtime/poll',
    idempotencyRequired: false,
    scopes: <String>['inbox:read'],
  ),
  listMyInboxItems(
    'GET',
    '/v1/subscriber/inbox/items',
    idempotencyRequired: false,
    scopes: <String>['inbox:read'],
  ),
  getMyInboxItem(
    'GET',
    '/v1/subscriber/inbox/items/{item_id}',
    idempotencyRequired: false,
    scopes: <String>['inbox:read'],
  ),
  applyMyInboxIntent(
    'POST',
    '/v1/subscriber/inbox/items/{item_id}/intents',
    idempotencyRequired: true,
    scopes: <String>['inbox:write'],
  ),
  respondToMyWaitpoint(
    'POST',
    '/v1/subscriber/waitpoints/{waitpoint_id}/response',
    idempotencyRequired: false,
    scopes: <String>['inbox:write'],
  ),
  getMyInboxCounters(
    'GET',
    '/v1/subscriber/inbox/counters',
    idempotencyRequired: false,
    scopes: <String>['inbox:read'],
  ),
  listMyInboxChanges(
    'GET',
    '/v1/subscriber/inbox/changes',
    idempotencyRequired: false,
    scopes: <String>['inbox:read'],
  ),
  markAllMyInboxRead(
    'POST',
    '/v1/subscriber/inbox/read_all',
    idempotencyRequired: true,
    scopes: <String>['inbox:write'],
  ),
  reportMyInboxInconsistency(
    'POST',
    '/v1/subscriber/inbox/counters/inconsistency',
    idempotencyRequired: false,
    scopes: <String>['inbox:read'],
  );

  const RelayOperation(
    this.method,
    this.path, {
    required this.idempotencyRequired,
    required this.scopes,
  });

  final String method;

  final String path;

  final bool idempotencyRequired;

  final List<String> scopes;
}

const String relayApiVersion = '2026-11-01';
