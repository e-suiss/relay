import type { components, paths } from './generated/subscriber';

type Json<R> = R extends { content: { 'application/json': infer B } } ? B : never;
type Ok<O, S extends number> = O extends { responses: Record<S, infer R> } ? Json<R> : never;
type Body<O> = O extends { requestBody?: { content: { 'application/json': infer B } } } ? B : never;

type Schemas = components['schemas'];

export type SubscriberPreferences = Ok<paths['/v1/subscriber/preferences']['get'], 200>;
export type MyPreferencesPatch = Body<paths['/v1/subscriber/preferences']['patch']>;
export type PreferenceCell = SubscriberPreferences['cells'][number];
export type PreferenceWrite = NonNullable<MyPreferencesPatch['preferences']>[number];
export type PreferenceValue = PreferenceCell['value'];
export type PreferenceProfile = SubscriberPreferences['profile'];
export type Channel = PreferenceCell['channel'];

export type DeviceRegistration = Body<paths['/v1/subscriber/devices']['post']>;
export type Device = Ok<paths['/v1/subscriber/devices']['post'], 201>;
export type DevicePlatform = DeviceRegistration['platform'];
export type DevicePermission = DeviceRegistration['permission'];
export type AndroidChannel = NonNullable<DeviceRegistration['android_channels']>[number];
export type AndroidChannelImportance = AndroidChannel['importance'];

export type DeviceStatusWrite = Schemas['DeviceStatusWrite'];
export type DeviceStatus = Schemas['DeviceStatus'];
export type DeviceStatusList = Schemas['DeviceStatusList'];
export type PushReceipt = Schemas['PushReceipt'];
export type PushReceiptRecorded = Schemas['PushReceiptRecorded'];

export type InboxItem = Schemas['InboxItem'];
export type InboxItemState = Schemas['InboxItemState'];
export type InboxItemList = Schemas['InboxItemList'];
export type InboxCounters = Schemas['InboxCounters'];
export type InboxChange = Schemas['InboxChange'];
export type InboxChanges = Schemas['InboxChanges'];
export type InboxIntent = Schemas['InboxIntent'];
export type InboxIntentOp = InboxIntent['op'];
export type InboxIntentResult = Schemas['InboxIntentResult'];
export type InboxReadAll = Schemas['InboxReadAll'];
export type InboxReadAllResult = Schemas['InboxReadAllResult'];
export type InboxReconciliation = Schemas['InboxReconciliation'];
export type RealtimeEnvelope = Schemas['RealtimeEnvelope'];
export type RealtimePoll = Schemas['RealtimePoll'];

export type DeviceInterruptionPermissions = Schemas['DeviceInterruptionPermissions'];
export type DeviceInterruptionPermission = Schemas['DeviceInterruptionPermission'];

export type Consent = Schemas['Consent'];
export type ConsentList = Schemas['ConsentList'];
export type ConsentStatus = Schemas['ConsentStatus'];

export type PushContentResponse = Schemas['PushContent'];

export type InboxSenderType = NonNullable<InboxItem['sender_type']>;
export type InboxWaitpoint = Schemas['InboxWaitpoint'];
export type InboxWaitpointStatus = InboxWaitpoint['status'];
export type InboxWaitpointOption = InboxWaitpoint['options'][number];
export type InboxWaitpointResponder = NonNullable<InboxWaitpoint['responder']>;
export type WaitpointResponseRequest = Schemas['WaitpointResponseRequest'];
export type WaitpointResponseReceipt = Schemas['WaitpointResponseReceipt'];
