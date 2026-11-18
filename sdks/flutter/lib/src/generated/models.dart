enum AndroidChannelImportance {
  none('none'),
  min('min'),
  low('low'),
  defaultValue('default'),
  high('high'),
  unrecognized('');

  const AndroidChannelImportance(this.wire);

  final String wire;

  static AndroidChannelImportance fromWire(String value) =>
      AndroidChannelImportance.values.firstWhere(
        (e) => e.wire == value,
        orElse: () => AndroidChannelImportance.unrecognized,
      );
}

enum ApnsEnvironment {
  production('production'),
  sandbox('sandbox'),
  unrecognized('');

  const ApnsEnvironment(this.wire);

  final String wire;

  static ApnsEnvironment fromWire(String value) =>
      ApnsEnvironment.values.firstWhere(
        (e) => e.wire == value,
        orElse: () => ApnsEnvironment.unrecognized,
      );
}

enum Channel {
  push('push'),
  webPush('web_push'),
  email('email'),
  sms('sms'),
  voice('voice'),
  whatsapp('whatsapp'),
  slack('slack'),
  teams('teams'),
  telegram('telegram'),
  discord('discord'),
  inApp('in_app'),
  webhook('webhook'),
  unrecognized('');

  const Channel(this.wire);

  final String wire;

  static Channel fromWire(String value) => Channel.values.firstWhere(
    (e) => e.wire == value,
    orElse: () => Channel.unrecognized,
  );
}

enum ConsentKind {
  explicitOptIn('explicit_opt_in'),
  softOptIn('soft_opt_in'),
  legitimateInterest('legitimate_interest'),
  none('none'),
  unrecognized('');

  const ConsentKind(this.wire);

  final String wire;

  static ConsentKind fromWire(String value) => ConsentKind.values.firstWhere(
    (e) => e.wire == value,
    orElse: () => ConsentKind.unrecognized,
  );
}

enum ConsentStatus {
  none('none'),
  pending('pending'),
  pendingIys('pending_iys'),
  active('active'),
  revoked('revoked'),
  expired('expired'),
  unrecognized('');

  const ConsentStatus(this.wire);

  final String wire;

  static ConsentStatus fromWire(String value) =>
      ConsentStatus.values.firstWhere(
        (e) => e.wire == value,
        orElse: () => ConsentStatus.unrecognized,
      );
}

enum DeviceDisabledReason {
  unregistered('unregistered'),
  logout('logout'),
  removed('removed'),
  replaced('replaced'),
  inactive('inactive'),
  deviceLimit('device_limit'),
  reassigned('reassigned'),
  erased('erased'),
  unrecognized('');

  const DeviceDisabledReason(this.wire);

  final String wire;

  static DeviceDisabledReason fromWire(String value) =>
      DeviceDisabledReason.values.firstWhere(
        (e) => e.wire == value,
        orElse: () => DeviceDisabledReason.unrecognized,
      );
}

enum DeviceInterruptionPermission {
  granted('granted'),
  denied('denied'),
  notDetermined('not_determined'),
  unrecognized('');

  const DeviceInterruptionPermission(this.wire);

  final String wire;

  static DeviceInterruptionPermission fromWire(String value) =>
      DeviceInterruptionPermission.values.firstWhere(
        (e) => e.wire == value,
        orElse: () => DeviceInterruptionPermission.unrecognized,
      );
}

enum DevicePermission {
  granted('granted'),
  denied('denied'),
  provisional('provisional'),
  notDetermined('not_determined'),
  unrecognized('');

  const DevicePermission(this.wire);

  final String wire;

  static DevicePermission fromWire(String value) =>
      DevicePermission.values.firstWhere(
        (e) => e.wire == value,
        orElse: () => DevicePermission.unrecognized,
      );
}

enum DevicePlatform {
  apns('apns'),
  fcm('fcm'),
  hms('hms'),
  webPush('web_push'),
  unifiedPush('unified_push'),
  unrecognized('');

  const DevicePlatform(this.wire);

  final String wire;

  static DevicePlatform fromWire(String value) =>
      DevicePlatform.values.firstWhere(
        (e) => e.wire == value,
        orElse: () => DevicePlatform.unrecognized,
      );
}

enum DeviceState {
  active('active'),
  stale('stale'),
  disabled('disabled'),
  unrecognized('');

  const DeviceState(this.wire);

  final String wire;

  static DeviceState fromWire(String value) => DeviceState.values.firstWhere(
    (e) => e.wire == value,
    orElse: () => DeviceState.unrecognized,
  );
}

enum EvidenceLevel {
  channelClaim('channel_claim'),
  relaySession('relay_session'),
  accessAasRef('access_aas_ref'),
  unrecognized('');

  const EvidenceLevel(this.wire);

  final String wire;

  static EvidenceLevel fromWire(String value) =>
      EvidenceLevel.values.firstWhere(
        (e) => e.wire == value,
        orElse: () => EvidenceLevel.unrecognized,
      );
}

enum LegalType {
  individual('individual'),
  merchant('merchant'),
  unrecognized('');

  const LegalType(this.wire);

  final String wire;

  static LegalType fromWire(String value) => LegalType.values.firstWhere(
    (e) => e.wire == value,
    orElse: () => LegalType.unrecognized,
  );
}

enum PreferenceLevel {
  categoryChannel('category_channel'),
  channel('channel'),
  workflow('workflow'),
  scopeKey('scope_key'),
  unrecognized('');

  const PreferenceLevel(this.wire);

  final String wire;

  static PreferenceLevel fromWire(String value) =>
      PreferenceLevel.values.firstWhere(
        (e) => e.wire == value,
        orElse: () => PreferenceLevel.unrecognized,
      );
}

enum PreferenceSource {
  user('user'),
  tenant('tenant'),
  categoryDefault('category_default'),
  classDefault('class_default'),
  locked('locked'),
  unrecognized('');

  const PreferenceSource(this.wire);

  final String wire;

  static PreferenceSource fromWire(String value) =>
      PreferenceSource.values.firstWhere(
        (e) => e.wire == value,
        orElse: () => PreferenceSource.unrecognized,
      );
}

enum PreferenceValue {
  optIn('opt_in'),
  optOut('opt_out'),
  unset('unset'),
  unrecognized('');

  const PreferenceValue(this.wire);

  final String wire;

  static PreferenceValue fromWire(String value) =>
      PreferenceValue.values.firstWhere(
        (e) => e.wire == value,
        orElse: () => PreferenceValue.unrecognized,
      );
}

class AndroidChannel {
  const AndroidChannel({required this.id, required this.importance});

  factory AndroidChannel.fromJson(Map<String, Object?> json) => AndroidChannel(
    id: json['id'] as String,
    importance: AndroidChannelImportance.fromWire(json['importance'] as String),
  );

  final String id;

  final AndroidChannelImportance importance;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'importance': importance.wire,
  };
}

class ChannelPreference {
  const ChannelPreference({required this.channel, required this.value});

  factory ChannelPreference.fromJson(Map<String, Object?> json) =>
      ChannelPreference(
        channel: Channel.fromWire(json['channel'] as String),
        value: PreferenceValue.fromWire(json['value'] as String),
      );

  final Channel channel;

  final PreferenceValue value;

  Map<String, Object?> toJson() => <String, Object?>{
    'channel': channel.wire,
    'value': value.wire,
  };
}

class Consent {
  const Consent({
    required this.object,
    required this.id,
    required this.brand,
    required this.channel,
    required this.status,
    required this.consentKind,
    required this.recipientType,
    required this.source,
    required this.occurredAt,
  });

  factory Consent.fromJson(Map<String, Object?> json) => Consent(
    object: json['object'] as String,
    id: json['id'] as String,
    brand: json['brand'] == null ? null : json['brand'] as String,
    channel: Channel.fromWire(json['channel'] as String),
    status: ConsentStatus.fromWire(json['status'] as String),
    consentKind: json['consent_kind'] == null
        ? null
        : ConsentKind.fromWire(json['consent_kind'] as String),
    recipientType: json['recipient_type'] == null
        ? null
        : LegalType.fromWire(json['recipient_type'] as String),
    source: json['source'] as String,
    occurredAt: json['occurred_at'] as String,
  );

  final String object;

  final String id;

  final String? brand;

  final Channel channel;

  final ConsentStatus status;

  final ConsentKind? consentKind;

  final LegalType? recipientType;

  final String source;

  final String occurredAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'object': object,
    'id': id,
    'brand': brand,
    'channel': channel.wire,
    'status': status.wire,
    'consent_kind': consentKind?.wire,
    'recipient_type': recipientType?.wire,
    'source': source,
    'occurred_at': occurredAt,
  };
}

class ConsentList {
  const ConsentList({
    required this.object,
    required this.data,
    required this.hasMore,
    required this.nextCursor,
    this.previousCursor,
  });

  factory ConsentList.fromJson(Map<String, Object?> json) => ConsentList(
    object: json['object'] as String,
    data: (json['data'] as List<Object?>)
        .map((Object? e0) => Consent.fromJson(e0 as Map<String, Object?>))
        .toList(),
    hasMore: json['has_more'] as bool,
    nextCursor: json['next_cursor'] == null
        ? null
        : json['next_cursor'] as String,
    previousCursor: json['previous_cursor'] == null
        ? null
        : json['previous_cursor'] as String,
  );

  final String object;

  final List<Consent> data;

  final bool hasMore;

  final String? nextCursor;

  final String? previousCursor;

  Map<String, Object?> toJson() => <String, Object?>{
    'object': object,
    'data': data.map((Consent e0) => e0.toJson()).toList(),
    'has_more': hasMore,
    'next_cursor': nextCursor,
    if (previousCursor != null) 'previous_cursor': previousCursor,
  };
}

class Device {
  const Device({
    required this.object,
    required this.id,
    required this.subscriberId,
    required this.platform,
    required this.app,
    required this.tokenFingerprint,
    required this.apnsEnvironment,
    required this.permission,
    required this.androidChannels,
    required this.locale,
    this.timezone,
    this.interruptionPermissions,
    required this.state,
    required this.disabledReason,
    required this.registeredAt,
    required this.lastSeenAt,
    required this.deletedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Device.fromJson(Map<String, Object?> json) => Device(
    object: json['object'] as String,
    id: json['id'] as String,
    subscriberId: json['subscriber_id'] as String,
    platform: DevicePlatform.fromWire(json['platform'] as String),
    app: json['app'] as String,
    tokenFingerprint: json['token_fingerprint'] as String,
    apnsEnvironment: json['apns_environment'] == null
        ? null
        : ApnsEnvironment.fromWire(json['apns_environment'] as String),
    permission: DevicePermission.fromWire(json['permission'] as String),
    androidChannels: (json['android_channels'] as List<Object?>)
        .map(
          (Object? e0) => AndroidChannel.fromJson(e0 as Map<String, Object?>),
        )
        .toList(),
    locale: json['locale'] == null ? null : json['locale'] as String,
    timezone: json['timezone'] == null ? null : json['timezone'] as String,
    interruptionPermissions: json['interruption_permissions'] == null
        ? null
        : DeviceInterruptionPermissions.fromJson(
            json['interruption_permissions'] as Map<String, Object?>,
          ),
    state: DeviceState.fromWire(json['state'] as String),
    disabledReason: json['disabled_reason'] == null
        ? null
        : DeviceDisabledReason.fromWire(json['disabled_reason'] as String),
    registeredAt: json['registered_at'] as String,
    lastSeenAt: json['last_seen_at'] as String,
    deletedAt: json['deleted_at'] == null ? null : json['deleted_at'] as String,
    createdAt: json['created_at'] as String,
    updatedAt: json['updated_at'] as String,
  );

  final String object;

  final String id;

  final String subscriberId;

  final DevicePlatform platform;

  final String app;

  final String tokenFingerprint;

  final ApnsEnvironment? apnsEnvironment;

  final DevicePermission permission;

  final List<AndroidChannel> androidChannels;

  final String? locale;

  final String? timezone;

  final DeviceInterruptionPermissions? interruptionPermissions;

  final DeviceState state;

  final DeviceDisabledReason? disabledReason;

  final String registeredAt;

  final String lastSeenAt;

  final String? deletedAt;

  final String createdAt;

  final String updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'object': object,
    'id': id,
    'subscriber_id': subscriberId,
    'platform': platform.wire,
    'app': app,
    'token_fingerprint': tokenFingerprint,
    'apns_environment': apnsEnvironment?.wire,
    'permission': permission.wire,
    'android_channels': androidChannels
        .map((AndroidChannel e0) => e0.toJson())
        .toList(),
    'locale': locale,
    if (timezone != null) 'timezone': timezone,
    if (interruptionPermissions != null)
      'interruption_permissions': interruptionPermissions!.toJson(),
    'state': state.wire,
    'disabled_reason': disabledReason?.wire,
    'registered_at': registeredAt,
    'last_seen_at': lastSeenAt,
    'deleted_at': deletedAt,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };
}

class DeviceInterruptionPermissions {
  const DeviceInterruptionPermissions({
    this.criticalAlerts,
    this.timeSensitive,
    this.dndAccess,
  });

  factory DeviceInterruptionPermissions.fromJson(Map<String, Object?> json) =>
      DeviceInterruptionPermissions(
        criticalAlerts: json['critical_alerts'] == null
            ? null
            : DeviceInterruptionPermission.fromWire(
                json['critical_alerts'] as String,
              ),
        timeSensitive: json['time_sensitive'] == null
            ? null
            : DeviceInterruptionPermission.fromWire(
                json['time_sensitive'] as String,
              ),
        dndAccess: json['dnd_access'] == null
            ? null
            : DeviceInterruptionPermission.fromWire(
                json['dnd_access'] as String,
              ),
      );

  final DeviceInterruptionPermission? criticalAlerts;

  final DeviceInterruptionPermission? timeSensitive;

  final DeviceInterruptionPermission? dndAccess;

  Map<String, Object?> toJson() => <String, Object?>{
    if (criticalAlerts != null) 'critical_alerts': criticalAlerts!.wire,
    if (timeSensitive != null) 'time_sensitive': timeSensitive!.wire,
    if (dndAccess != null) 'dnd_access': dndAccess!.wire,
  };
}

class DeviceRegistration {
  const DeviceRegistration({
    required this.platform,
    required this.token,
    this.keys,
    required this.app,
    this.apnsEnvironment,
    required this.permission,
    this.androidChannels,
    this.locale,
    this.timezone,
    this.interruptionPermissions,
    this.previousToken,
  });

  factory DeviceRegistration.fromJson(Map<String, Object?> json) =>
      DeviceRegistration(
        platform: DevicePlatform.fromWire(json['platform'] as String),
        token: json['token'] as String,
        keys: json['keys'] == null
            ? null
            : WebPushKeys.fromJson(json['keys'] as Map<String, Object?>),
        app: json['app'] as String,
        apnsEnvironment: json['apns_environment'] == null
            ? null
            : ApnsEnvironment.fromWire(json['apns_environment'] as String),
        permission: DevicePermission.fromWire(json['permission'] as String),
        androidChannels: json['android_channels'] == null
            ? null
            : (json['android_channels'] as List<Object?>)
                  .map(
                    (Object? e0) =>
                        AndroidChannel.fromJson(e0 as Map<String, Object?>),
                  )
                  .toList(),
        locale: json['locale'] == null ? null : json['locale'] as String,
        timezone: json['timezone'] == null ? null : json['timezone'] as String,
        interruptionPermissions: json['interruption_permissions'] == null
            ? null
            : DeviceInterruptionPermissions.fromJson(
                json['interruption_permissions'] as Map<String, Object?>,
              ),
        previousToken: json['previous_token'] == null
            ? null
            : json['previous_token'] as String,
      );

  final DevicePlatform platform;

  final String token;

  final WebPushKeys? keys;

  final String app;

  final ApnsEnvironment? apnsEnvironment;

  final DevicePermission permission;

  final List<AndroidChannel>? androidChannels;

  final String? locale;

  final String? timezone;

  final DeviceInterruptionPermissions? interruptionPermissions;

  final String? previousToken;

  Map<String, Object?> toJson() => <String, Object?>{
    'platform': platform.wire,
    'token': token,
    if (keys != null) 'keys': keys!.toJson(),
    'app': app,
    if (apnsEnvironment != null) 'apns_environment': apnsEnvironment!.wire,
    'permission': permission.wire,
    if (androidChannels != null)
      'android_channels': androidChannels!
          .map((AndroidChannel e0) => e0.toJson())
          .toList(),
    if (locale != null) 'locale': locale,
    if (timezone != null) 'timezone': timezone,
    if (interruptionPermissions != null)
      'interruption_permissions': interruptionPermissions!.toJson(),
    if (previousToken != null) 'previous_token': previousToken,
  };
}

class DeviceStatus {
  const DeviceStatus({
    required this.object,
    required this.deviceId,
    required this.version,
    required this.signals,
  });

  factory DeviceStatus.fromJson(Map<String, Object?> json) => DeviceStatus(
    object: json['object'] as String,
    deviceId: json['device_id'] as String,
    version: json['version'] as String,
    signals: DeviceStatusSignals.fromJson(
      json['signals'] as Map<String, Object?>,
    ),
  );

  final String object;

  final String deviceId;

  final String version;

  final DeviceStatusSignals signals;

  Map<String, Object?> toJson() => <String, Object?>{
    'object': object,
    'device_id': deviceId,
    'version': version,
    'signals': signals.toJson(),
  };
}

class DeviceStatusList {
  const DeviceStatusList({required this.object, required this.data});

  factory DeviceStatusList.fromJson(Map<String, Object?> json) =>
      DeviceStatusList(
        object: json['object'] as String,
        data: (json['data'] as List<Object?>)
            .map(
              (Object? e0) => DeviceStatus.fromJson(e0 as Map<String, Object?>),
            )
            .toList(),
      );

  final String object;

  final List<DeviceStatus> data;

  Map<String, Object?> toJson() => <String, Object?>{
    'object': object,
    'data': data.map((DeviceStatus e0) => e0.toJson()).toList(),
  };
}

class DeviceStatusSignals {
  const DeviceStatusSignals({
    required this.worn,
    required this.locked,
    required this.headphones,
    required this.focus,
    required this.breakValue,
  });

  factory DeviceStatusSignals.fromJson(Map<String, Object?> json) =>
      DeviceStatusSignals(
        worn: json['worn'],
        locked: json['locked'],
        headphones: json['headphones'],
        focus: json['focus'],
        breakValue: json['break'],
      );

  final Object? worn;

  final Object? locked;

  final Object? headphones;

  final Object? focus;

  final Object? breakValue;

  Map<String, Object?> toJson() => <String, Object?>{
    'worn': worn,
    'locked': locked,
    'headphones': headphones,
    'focus': focus,
    'break': breakValue,
  };
}

class DeviceStatusWrite {
  const DeviceStatusWrite({
    required this.version,
    required this.signals,
    this.ttl,
  });

  factory DeviceStatusWrite.fromJson(Map<String, Object?> json) =>
      DeviceStatusWrite(
        version: json['version'] as String,
        signals: DeviceStatusWriteSignals.fromJson(
          json['signals'] as Map<String, Object?>,
        ),
        ttl: json['ttl'] == null ? null : json['ttl'] as String,
      );

  final String version;

  final DeviceStatusWriteSignals signals;

  final String? ttl;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'signals': signals.toJson(),
    if (ttl != null) 'ttl': ttl,
  };
}

class DeviceStatusWriteSignals {
  const DeviceStatusWriteSignals({
    this.worn,
    this.locked,
    this.headphones,
    this.focus,
    this.breakValue,
  });

  factory DeviceStatusWriteSignals.fromJson(Map<String, Object?> json) =>
      DeviceStatusWriteSignals(
        worn: json['worn'],
        locked: json['locked'],
        headphones: json['headphones'],
        focus: json['focus'],
        breakValue: json['break'],
      );

  final Object? worn;

  final Object? locked;

  final Object? headphones;

  final Object? focus;

  final Object? breakValue;

  Map<String, Object?> toJson() => <String, Object?>{
    if (worn != null) 'worn': worn,
    if (locked != null) 'locked': locked,
    if (headphones != null) 'headphones': headphones,
    if (focus != null) 'focus': focus,
    if (breakValue != null) 'break': breakValue,
  };
}

class InboxChange {
  const InboxChange({
    required this.type,
    required this.itemId,
    required this.stateVersion,
    required this.cursor,
    required this.item,
  });

  factory InboxChange.fromJson(Map<String, Object?> json) => InboxChange(
    type: json['type'] as String,
    itemId: json['item_id'] as String,
    stateVersion: (json['state_version'] as num).toInt(),
    cursor: json['cursor'] as String,
    item: json['item'] as Map<String, Object?>,
  );

  final String type;

  final String itemId;

  final int stateVersion;

  final String cursor;

  final Map<String, Object?> item;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'item_id': itemId,
    'state_version': stateVersion,
    'cursor': cursor,
    'item': item,
  };
}

class InboxChanges {
  const InboxChanges({
    required this.object,
    required this.changes,
    required this.cursor,
    required this.hasMore,
    required this.truncated,
    required this.resyncRequired,
    this.resyncReason,
    required this.counters,
  });

  factory InboxChanges.fromJson(Map<String, Object?> json) => InboxChanges(
    object: json['object'] as String,
    changes: (json['changes'] as List<Object?>)
        .map((Object? e0) => InboxChange.fromJson(e0 as Map<String, Object?>))
        .toList(),
    cursor: json['cursor'] as String,
    hasMore: json['has_more'] as bool,
    truncated: json['truncated'] as bool,
    resyncRequired: json['resync_required'] as bool,
    resyncReason: json['resync_reason'] == null
        ? null
        : json['resync_reason'] as String,
    counters: InboxCounters.fromJson(json['counters'] as Map<String, Object?>),
  );

  final String object;

  final List<InboxChange> changes;

  final String cursor;

  final bool hasMore;

  final bool truncated;

  final bool resyncRequired;

  final String? resyncReason;

  final InboxCounters counters;

  Map<String, Object?> toJson() => <String, Object?>{
    'object': object,
    'changes': changes.map((InboxChange e0) => e0.toJson()).toList(),
    'cursor': cursor,
    'has_more': hasMore,
    'truncated': truncated,
    'resync_required': resyncRequired,
    if (resyncReason != null) 'resync_reason': resyncReason,
    'counters': counters.toJson(),
  };
}

class InboxCounters {
  const InboxCounters({
    required this.object,
    required this.unseen,
    required this.unread,
    required this.total,
    required this.version,
  });

  factory InboxCounters.fromJson(Map<String, Object?> json) => InboxCounters(
    object: json['object'] as String,
    unseen: (json['unseen'] as num).toInt(),
    unread: (json['unread'] as num).toInt(),
    total: (json['total'] as num).toInt(),
    version: (json['version'] as num).toInt(),
  );

  final String object;

  final int unseen;

  final int unread;

  final int total;

  final int version;

  Map<String, Object?> toJson() => <String, Object?>{
    'object': object,
    'unseen': unseen,
    'unread': unread,
    'total': total,
    'version': version,
  };
}

class InboxIntent {
  const InboxIntent({
    required this.op,
    this.baseStateVersion,
    this.clientSeq,
    this.snoozeUntil,
  });

  factory InboxIntent.fromJson(Map<String, Object?> json) => InboxIntent(
    op: json['op'] as String,
    baseStateVersion: json['base_state_version'] == null
        ? null
        : (json['base_state_version'] as num).toInt(),
    clientSeq: json['client_seq'] == null
        ? null
        : (json['client_seq'] as num).toInt(),
    snoozeUntil: json['snooze_until'] == null
        ? null
        : json['snooze_until'] as String,
  );

  final String op;

  final int? baseStateVersion;

  final int? clientSeq;

  final String? snoozeUntil;

  Map<String, Object?> toJson() => <String, Object?>{
    'op': op,
    if (baseStateVersion != null) 'base_state_version': baseStateVersion,
    if (clientSeq != null) 'client_seq': clientSeq,
    if (snoozeUntil != null) 'snooze_until': snoozeUntil,
  };
}

class InboxIntentResult {
  const InboxIntentResult({
    required this.object,
    required this.itemId,
    required this.op,
    required this.clientSeq,
    required this.result,
    required this.state,
    required this.counters,
  });

  factory InboxIntentResult.fromJson(Map<String, Object?> json) =>
      InboxIntentResult(
        object: json['object'] as String,
        itemId: json['item_id'] as String,
        op: json['op'] as String,
        clientSeq: json['client_seq'] == null
            ? null
            : (json['client_seq'] as num).toInt(),
        result: json['result'] as String,
        state: InboxItemState.fromJson(json['state'] as Map<String, Object?>),
        counters: InboxCounters.fromJson(
          json['counters'] as Map<String, Object?>,
        ),
      );

  final String object;

  final String itemId;

  final String op;

  final int? clientSeq;

  final String result;

  final InboxItemState state;

  final InboxCounters counters;

  Map<String, Object?> toJson() => <String, Object?>{
    'object': object,
    'item_id': itemId,
    'op': op,
    'client_seq': clientSeq,
    'result': result,
    'state': state.toJson(),
    'counters': counters.toJson(),
  };
}

class InboxItem {
  const InboxItem({
    required this.object,
    this.kind,
    required this.id,
    required this.stateVersion,
    required this.seen,
    required this.read,
    required this.archived,
    required this.hidden,
    required this.expired,
    required this.snoozedUntil,
    required this.seenAt,
    required this.readAt,
    required this.archivedAt,
    required this.createdAt,
    required this.lastActivityAt,
    required this.category,
    required this.tags,
    required this.severity,
    required this.groupKey,
    required this.title,
    required this.body,
    required this.avatarUrl,
    required this.url,
    required this.actions,
    required this.data,
    required this.locale,
    required this.dir,
    required this.activityCount,
    required this.actorCount,
    required this.expiresAt,
    this.senderType,
    this.approval,
    this.waitpoint,
  });

  factory InboxItem.fromJson(Map<String, Object?> json) => InboxItem(
    object: json['object'] as String,
    kind: json['kind'] == null ? null : json['kind'] as String,
    id: json['id'] as String,
    stateVersion: (json['state_version'] as num).toInt(),
    seen: json['seen'] as bool,
    read: json['read'] as bool,
    archived: json['archived'] as bool,
    hidden: json['hidden'] as bool,
    expired: json['expired'] as bool,
    snoozedUntil: json['snoozed_until'] == null
        ? null
        : json['snoozed_until'] as String,
    seenAt: json['seen_at'] == null ? null : json['seen_at'] as String,
    readAt: json['read_at'] == null ? null : json['read_at'] as String,
    archivedAt: json['archived_at'] == null
        ? null
        : json['archived_at'] as String,
    createdAt: json['created_at'] as String,
    lastActivityAt: json['last_activity_at'] as String,
    category: json['category'] == null ? null : json['category'] as String,
    tags: (json['tags'] as List<Object?>)
        .map((Object? e0) => e0 as String)
        .toList(),
    severity: json['severity'] == null ? null : json['severity'] as String,
    groupKey: json['group_key'] == null ? null : json['group_key'] as String,
    title: json['title'] == null ? null : json['title'] as String,
    body: json['body'] == null ? null : json['body'] as String,
    avatarUrl: json['avatar_url'] == null ? null : json['avatar_url'] as String,
    url: json['url'] == null ? null : json['url'] as String,
    actions: (json['actions'] as List<Object?>)
        .map(
          (Object? e0) =>
              InboxItemActionsItem.fromJson(e0 as Map<String, Object?>),
        )
        .toList(),
    data: (json['data'] as List<Object?>)
        .map(
          (Object? e0) =>
              InboxItemDataItem.fromJson(e0 as Map<String, Object?>),
        )
        .toList(),
    locale: json['locale'] == null ? null : json['locale'] as String,
    dir: json['dir'] == null ? null : json['dir'] as String,
    activityCount: (json['activity_count'] as num).toInt(),
    actorCount: (json['actor_count'] as num).toInt(),
    expiresAt: json['expires_at'] == null ? null : json['expires_at'] as String,
    senderType: json['sender_type'] == null
        ? null
        : json['sender_type'] as String,
    approval: json['approval'] == null ? null : json['approval'] as bool,
    waitpoint: json['waitpoint'] == null
        ? null
        : InboxWaitpoint.fromJson(json['waitpoint'] as Map<String, Object?>),
  );

  final String object;

  final String? kind;

  final String id;

  final int stateVersion;

  final bool seen;

  final bool read;

  final bool archived;

  final bool hidden;

  final bool expired;

  final String? snoozedUntil;

  final String? seenAt;

  final String? readAt;

  final String? archivedAt;

  final String createdAt;

  final String lastActivityAt;

  final String? category;

  final List<String> tags;

  final String? severity;

  final String? groupKey;

  final String? title;

  final String? body;

  final String? avatarUrl;

  final String? url;

  final List<InboxItemActionsItem> actions;

  final List<InboxItemDataItem> data;

  final String? locale;

  final String? dir;

  final int activityCount;

  final int actorCount;

  final String? expiresAt;

  final String? senderType;

  final bool? approval;

  final InboxWaitpoint? waitpoint;

  Map<String, Object?> toJson() => <String, Object?>{
    'object': object,
    if (kind != null) 'kind': kind,
    'id': id,
    'state_version': stateVersion,
    'seen': seen,
    'read': read,
    'archived': archived,
    'hidden': hidden,
    'expired': expired,
    'snoozed_until': snoozedUntil,
    'seen_at': seenAt,
    'read_at': readAt,
    'archived_at': archivedAt,
    'created_at': createdAt,
    'last_activity_at': lastActivityAt,
    'category': category,
    'tags': tags,
    'severity': severity,
    'group_key': groupKey,
    'title': title,
    'body': body,
    'avatar_url': avatarUrl,
    'url': url,
    'actions': actions.map((InboxItemActionsItem e0) => e0.toJson()).toList(),
    'data': data.map((InboxItemDataItem e0) => e0.toJson()).toList(),
    'locale': locale,
    'dir': dir,
    'activity_count': activityCount,
    'actor_count': actorCount,
    'expires_at': expiresAt,
    if (senderType != null) 'sender_type': senderType,
    if (approval != null) 'approval': approval,
    if (waitpoint != null) 'waitpoint': waitpoint!.toJson(),
  };
}

class InboxItemActionsItem {
  const InboxItemActionsItem({required this.label, required this.url});

  factory InboxItemActionsItem.fromJson(Map<String, Object?> json) =>
      InboxItemActionsItem(
        label: json['label'] as String,
        url: json['url'] as String,
      );

  final String label;

  final String url;

  Map<String, Object?> toJson() => <String, Object?>{
    'label': label,
    'url': url,
  };
}

class InboxItemDataItem {
  const InboxItemDataItem({required this.key, required this.value});

  factory InboxItemDataItem.fromJson(Map<String, Object?> json) =>
      InboxItemDataItem(
        key: json['key'] as String,
        value: json['value'] as String,
      );

  final String key;

  final String value;

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'value': value,
  };
}

class InboxItemList {
  const InboxItemList({
    required this.object,
    required this.data,
    required this.hasMore,
    required this.nextCursor,
    required this.previousCursor,
    this.counters,
    this.cursor,
  });

  factory InboxItemList.fromJson(Map<String, Object?> json) => InboxItemList(
    object: json['object'] as String,
    data: (json['data'] as List<Object?>)
        .map((Object? e0) => InboxItem.fromJson(e0 as Map<String, Object?>))
        .toList(),
    hasMore: json['has_more'] as bool,
    nextCursor: json['next_cursor'] == null
        ? null
        : json['next_cursor'] as String,
    previousCursor: json['previous_cursor'],
    counters: json['counters'] == null
        ? null
        : InboxCounters.fromJson(json['counters'] as Map<String, Object?>),
    cursor: json['cursor'] == null ? null : json['cursor'] as String,
  );

  final String object;

  final List<InboxItem> data;

  final bool hasMore;

  final String? nextCursor;

  final Object? previousCursor;

  final InboxCounters? counters;

  final String? cursor;

  Map<String, Object?> toJson() => <String, Object?>{
    'object': object,
    'data': data.map((InboxItem e0) => e0.toJson()).toList(),
    'has_more': hasMore,
    'next_cursor': nextCursor,
    'previous_cursor': previousCursor,
    if (counters != null) 'counters': counters!.toJson(),
    if (cursor != null) 'cursor': cursor,
  };
}

class InboxItemState {
  const InboxItemState({
    required this.id,
    required this.stateVersion,
    required this.seen,
    required this.read,
    required this.archived,
    required this.hidden,
    required this.expired,
    required this.snoozedUntil,
    required this.seenAt,
    required this.readAt,
    required this.archivedAt,
  });

  factory InboxItemState.fromJson(Map<String, Object?> json) => InboxItemState(
    id: json['id'] as String,
    stateVersion: (json['state_version'] as num).toInt(),
    seen: json['seen'] as bool,
    read: json['read'] as bool,
    archived: json['archived'] as bool,
    hidden: json['hidden'] as bool,
    expired: json['expired'] as bool,
    snoozedUntil: json['snoozed_until'] == null
        ? null
        : json['snoozed_until'] as String,
    seenAt: json['seen_at'] == null ? null : json['seen_at'] as String,
    readAt: json['read_at'] == null ? null : json['read_at'] as String,
    archivedAt: json['archived_at'] == null
        ? null
        : json['archived_at'] as String,
  );

  final String id;

  final int stateVersion;

  final bool seen;

  final bool read;

  final bool archived;

  final bool hidden;

  final bool expired;

  final String? snoozedUntil;

  final String? seenAt;

  final String? readAt;

  final String? archivedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'state_version': stateVersion,
    'seen': seen,
    'read': read,
    'archived': archived,
    'hidden': hidden,
    'expired': expired,
    'snoozed_until': snoozedUntil,
    'seen_at': seenAt,
    'read_at': readAt,
    'archived_at': archivedAt,
  };
}

class InboxReadAll {
  const InboxReadAll({this.category});

  factory InboxReadAll.fromJson(Map<String, Object?> json) => InboxReadAll(
    category: json['category'] == null ? null : json['category'] as String,
  );

  final String? category;

  Map<String, Object?> toJson() => <String, Object?>{
    if (category != null) 'category': category,
  };
}

class InboxReadAllResult {
  const InboxReadAllResult({
    required this.object,
    required this.scope,
    required this.category,
    required this.updated,
    required this.cutOff,
    required this.counters,
  });

  factory InboxReadAllResult.fromJson(Map<String, Object?> json) =>
      InboxReadAllResult(
        object: json['object'] as String,
        scope: json['scope'] as String,
        category: json['category'] == null ? null : json['category'] as String,
        updated: (json['updated'] as num).toInt(),
        cutOff: json['cut_off'] as String,
        counters: InboxCounters.fromJson(
          json['counters'] as Map<String, Object?>,
        ),
      );

  final String object;

  final String scope;

  final String? category;

  final int updated;

  final String cutOff;

  final InboxCounters counters;

  Map<String, Object?> toJson() => <String, Object?>{
    'object': object,
    'scope': scope,
    'category': category,
    'updated': updated,
    'cut_off': cutOff,
    'counters': counters.toJson(),
  };
}

class InboxReconciliation {
  const InboxReconciliation({
    required this.object,
    required this.result,
    required this.counters,
  });

  factory InboxReconciliation.fromJson(Map<String, Object?> json) =>
      InboxReconciliation(
        object: json['object'] as String,
        result: json['result'] as String,
        counters: InboxCounters.fromJson(
          json['counters'] as Map<String, Object?>,
        ),
      );

  final String object;

  final String result;

  final InboxCounters counters;

  Map<String, Object?> toJson() => <String, Object?>{
    'object': object,
    'result': result,
    'counters': counters.toJson(),
  };
}

class InboxWaitpoint {
  const InboxWaitpoint({
    required this.id,
    required this.kind,
    required this.status,
    required this.subjectDigest,
    required this.options,
    required this.responder,
    required this.respondedAt,
    required this.approvalUrl,
  });

  factory InboxWaitpoint.fromJson(Map<String, Object?> json) => InboxWaitpoint(
    id: json['id'] as String,
    kind: json['kind'] as String,
    status: json['status'] as String,
    subjectDigest: json['subject_digest'] == null
        ? null
        : json['subject_digest'] as String,
    options: (json['options'] as List<Object?>)
        .map(
          (Object? e0) =>
              InboxWaitpointOptionsItem.fromJson(e0 as Map<String, Object?>),
        )
        .toList(),
    responder: json['responder'] == null
        ? null
        : InboxWaitpointResponder.fromJson(
            json['responder'] as Map<String, Object?>,
          ),
    respondedAt: json['responded_at'] == null
        ? null
        : json['responded_at'] as String,
    approvalUrl: json['approval_url'] == null
        ? null
        : json['approval_url'] as String,
  );

  final String id;

  final String kind;

  final String status;

  final String? subjectDigest;

  final List<InboxWaitpointOptionsItem> options;

  final InboxWaitpointResponder? responder;

  final String? respondedAt;

  final String? approvalUrl;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind,
    'status': status,
    'subject_digest': subjectDigest,
    'options': options
        .map((InboxWaitpointOptionsItem e0) => e0.toJson())
        .toList(),
    'responder': responder?.toJson(),
    'responded_at': respondedAt,
    'approval_url': approvalUrl,
  };
}

class InboxWaitpointOptionsItem {
  const InboxWaitpointOptionsItem({required this.label, required this.value});

  factory InboxWaitpointOptionsItem.fromJson(Map<String, Object?> json) =>
      InboxWaitpointOptionsItem(
        label: json['label'] as String,
        value: json['value'] as String,
      );

  final String label;

  final String value;

  Map<String, Object?> toJson() => <String, Object?>{
    'label': label,
    'value': value,
  };
}

class InboxWaitpointResponder {
  const InboxWaitpointResponder({
    required this.kind,
    required this.recipientId,
  });

  factory InboxWaitpointResponder.fromJson(Map<String, Object?> json) =>
      InboxWaitpointResponder(
        kind: json['kind'] as String,
        recipientId: json['recipient_id'] as String,
      );

  final String kind;

  final String recipientId;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'recipient_id': recipientId,
  };
}

class MyPreferencesPatch {
  const MyPreferencesPatch({this.preferences, this.profile});

  factory MyPreferencesPatch.fromJson(Map<String, Object?> json) =>
      MyPreferencesPatch(
        preferences: json['preferences'] == null
            ? null
            : (json['preferences'] as List<Object?>)
                  .map(
                    (Object? e0) =>
                        PreferenceWrite.fromJson(e0 as Map<String, Object?>),
                  )
                  .toList(),
        profile: json['profile'] == null
            ? null
            : PreferenceProfileWrite.fromJson(
                json['profile'] as Map<String, Object?>,
              ),
      );

  final List<PreferenceWrite>? preferences;

  final PreferenceProfileWrite? profile;

  Map<String, Object?> toJson() => <String, Object?>{
    if (preferences != null)
      'preferences': preferences!
          .map((PreferenceWrite e0) => e0.toJson())
          .toList(),
    if (profile != null) 'profile': profile!.toJson(),
  };
}

class PreferenceCell {
  const PreferenceCell({
    required this.category,
    required this.categoryName,
    required this.channel,
    required this.value,
    required this.effective,
    required this.source,
    required this.locked,
    required this.lockBeneficiary,
    required this.digestAllowed,
    required this.disabledByAdmin,
    required this.disabledInDeviceSettings,
  });

  factory PreferenceCell.fromJson(Map<String, Object?> json) => PreferenceCell(
    category: json['category'] as String,
    categoryName: json['category_name'] as String,
    channel: Channel.fromWire(json['channel'] as String),
    value: PreferenceValue.fromWire(json['value'] as String),
    effective: json['effective'] as bool,
    source: PreferenceSource.fromWire(json['source'] as String),
    locked: json['locked'] as bool,
    lockBeneficiary: json['lock_beneficiary'] == null
        ? null
        : json['lock_beneficiary'] as String,
    digestAllowed: json['digest_allowed'] as bool,
    disabledByAdmin: json['disabled_by_admin'] as bool,
    disabledInDeviceSettings: json['disabled_in_device_settings'] as bool,
  );

  final String category;

  final String categoryName;

  final Channel channel;

  final PreferenceValue value;

  final bool effective;

  final PreferenceSource source;

  final bool locked;

  final String? lockBeneficiary;

  final bool digestAllowed;

  final bool disabledByAdmin;

  final bool disabledInDeviceSettings;

  Map<String, Object?> toJson() => <String, Object?>{
    'category': category,
    'category_name': categoryName,
    'channel': channel.wire,
    'value': value.wire,
    'effective': effective,
    'source': source.wire,
    'locked': locked,
    'lock_beneficiary': lockBeneficiary,
    'digest_allowed': digestAllowed,
    'disabled_by_admin': disabledByAdmin,
    'disabled_in_device_settings': disabledInDeviceSettings,
  };
}

class PreferenceProfile {
  const PreferenceProfile({
    required this.quietHours,
    required this.schedule,
    required this.dndUntil,
    required this.quietHoursEmail,
    required this.digest,
  });

  factory PreferenceProfile.fromJson(Map<String, Object?> json) =>
      PreferenceProfile(
        quietHours: (json['quiet_hours'] as List<Object?>)
            .map((Object? e0) => TimeRange.fromJson(e0 as Map<String, Object?>))
            .toList(),
        schedule: (json['schedule'] as List<Object?>)
            .map((Object? e0) => TimeRange.fromJson(e0 as Map<String, Object?>))
            .toList(),
        dndUntil: json['dnd_until'] == null
            ? null
            : json['dnd_until'] as String,
        quietHoursEmail: json['quiet_hours_email'] as bool,
        digest: (json['digest'] as Map<String, Object?>).map(
          (String k, Object? v) => MapEntry<String, String>(k, v as String),
        ),
      );

  final List<TimeRange> quietHours;

  final List<TimeRange> schedule;

  final String? dndUntil;

  final bool quietHoursEmail;

  final Map<String, String> digest;

  Map<String, Object?> toJson() => <String, Object?>{
    'quiet_hours': quietHours.map((TimeRange e0) => e0.toJson()).toList(),
    'schedule': schedule.map((TimeRange e0) => e0.toJson()).toList(),
    'dnd_until': dndUntil,
    'quiet_hours_email': quietHoursEmail,
    'digest': digest,
  };
}

class PreferenceProfileWrite {
  const PreferenceProfileWrite({
    this.quietHours,
    this.schedule,
    this.dndUntil,
    this.quietHoursEmail,
    this.digest,
  });

  factory PreferenceProfileWrite.fromJson(Map<String, Object?> json) =>
      PreferenceProfileWrite(
        quietHours: json['quiet_hours'] == null
            ? null
            : (json['quiet_hours'] as List<Object?>)
                  .map(
                    (Object? e0) =>
                        TimeRange.fromJson(e0 as Map<String, Object?>),
                  )
                  .toList(),
        schedule: json['schedule'] == null
            ? null
            : (json['schedule'] as List<Object?>)
                  .map(
                    (Object? e0) =>
                        TimeRange.fromJson(e0 as Map<String, Object?>),
                  )
                  .toList(),
        dndUntil: json['dnd_until'] == null
            ? null
            : json['dnd_until'] as String,
        quietHoursEmail: json['quiet_hours_email'] == null
            ? null
            : json['quiet_hours_email'] as bool,
        digest: json['digest'] == null
            ? null
            : (json['digest'] as Map<String, Object?>).map(
                (String k, Object? v) =>
                    MapEntry<String, String>(k, v as String),
              ),
      );

  final List<TimeRange>? quietHours;

  final List<TimeRange>? schedule;

  final String? dndUntil;

  final bool? quietHoursEmail;

  final Map<String, String>? digest;

  Map<String, Object?> toJson() => <String, Object?>{
    if (quietHours != null)
      'quiet_hours': quietHours!.map((TimeRange e0) => e0.toJson()).toList(),
    if (schedule != null)
      'schedule': schedule!.map((TimeRange e0) => e0.toJson()).toList(),
    if (dndUntil != null) 'dnd_until': dndUntil,
    if (quietHoursEmail != null) 'quiet_hours_email': quietHoursEmail,
    if (digest != null) 'digest': digest,
  };
}

class PreferenceWrite {
  const PreferenceWrite({
    required this.level,
    this.category,
    this.channel,
    this.workflow,
    this.scopeKey,
    required this.value,
  });

  factory PreferenceWrite.fromJson(Map<String, Object?> json) =>
      PreferenceWrite(
        level: PreferenceLevel.fromWire(json['level'] as String),
        category: json['category'] == null ? null : json['category'] as String,
        channel: json['channel'] == null
            ? null
            : Channel.fromWire(json['channel'] as String),
        workflow: json['workflow'] == null ? null : json['workflow'] as String,
        scopeKey: json['scope_key'] == null
            ? null
            : json['scope_key'] as String,
        value: PreferenceValue.fromWire(json['value'] as String),
      );

  final PreferenceLevel level;

  final String? category;

  final Channel? channel;

  final String? workflow;

  final String? scopeKey;

  final PreferenceValue value;

  Map<String, Object?> toJson() => <String, Object?>{
    'level': level.wire,
    if (category != null) 'category': category,
    if (channel != null) 'channel': channel!.wire,
    if (workflow != null) 'workflow': workflow,
    if (scopeKey != null) 'scope_key': scopeKey,
    'value': value.wire,
  };
}

class PushContent {
  const PushContent({
    required this.object,
    required this.deliveryId,
    required this.notificationId,
    required this.channel,
    required this.locale,
    required this.content,
  });

  factory PushContent.fromJson(Map<String, Object?> json) => PushContent(
    object: json['object'] as String,
    deliveryId: json['delivery_id'] as String,
    notificationId: json['notification_id'] as String,
    channel: json['channel'] as String,
    locale: json['locale'] == null ? null : json['locale'] as String,
    content: json['content'] as Map<String, Object?>,
  );

  final String object;

  final String deliveryId;

  final String notificationId;

  final String channel;

  final String? locale;

  final Map<String, Object?> content;

  Map<String, Object?> toJson() => <String, Object?>{
    'object': object,
    'delivery_id': deliveryId,
    'notification_id': notificationId,
    'channel': channel,
    'locale': locale,
    'content': content,
  };
}

class PushReceipt {
  const PushReceipt({
    required this.deliveryId,
    required this.receipt,
    this.occurredAt,
  });

  factory PushReceipt.fromJson(Map<String, Object?> json) => PushReceipt(
    deliveryId: json['delivery_id'] as String,
    receipt: json['receipt'] as String,
    occurredAt: json['occurred_at'] == null
        ? null
        : json['occurred_at'] as String,
  );

  final String deliveryId;

  final String receipt;

  final String? occurredAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'delivery_id': deliveryId,
    'receipt': receipt,
    if (occurredAt != null) 'occurred_at': occurredAt,
  };
}

class PushReceiptRecorded {
  const PushReceiptRecorded({
    required this.object,
    required this.deliveryId,
    required this.receipt,
  });

  factory PushReceiptRecorded.fromJson(Map<String, Object?> json) =>
      PushReceiptRecorded(
        object: json['object'] as String,
        deliveryId: json['delivery_id'] as String,
        receipt: json['receipt'] as String,
      );

  final String object;

  final String deliveryId;

  final String receipt;

  Map<String, Object?> toJson() => <String, Object?>{
    'object': object,
    'delivery_id': deliveryId,
    'receipt': receipt,
  };
}

class RealtimeEnvelope {
  const RealtimeEnvelope({
    required this.t,
    required this.v,
    required this.ts,
    this.id,
    required this.d,
    required this.counters,
  });

  factory RealtimeEnvelope.fromJson(Map<String, Object?> json) =>
      RealtimeEnvelope(
        t: json['t'] as String,
        v: (json['v'] as num).toInt(),
        ts: json['ts'] as String,
        id: json['id'] == null ? null : json['id'] as String,
        d: json['d'] as Map<String, Object?>,
        counters: RealtimeEnvelopeCounters.fromJson(
          json['counters'] as Map<String, Object?>,
        ),
      );

  final String t;

  final int v;

  final String ts;

  final String? id;

  final Map<String, Object?> d;

  final RealtimeEnvelopeCounters counters;

  Map<String, Object?> toJson() => <String, Object?>{
    't': t,
    'v': v,
    'ts': ts,
    if (id != null) 'id': id,
    'd': d,
    'counters': counters.toJson(),
  };
}

class RealtimeEnvelopeCounters {
  const RealtimeEnvelopeCounters({
    required this.unseen,
    required this.unread,
    required this.total,
    required this.version,
  });

  factory RealtimeEnvelopeCounters.fromJson(Map<String, Object?> json) =>
      RealtimeEnvelopeCounters(
        unseen: (json['unseen'] as num).toInt(),
        unread: (json['unread'] as num).toInt(),
        total: (json['total'] as num).toInt(),
        version: (json['version'] as num).toInt(),
      );

  final int unseen;

  final int unread;

  final int total;

  final int version;

  Map<String, Object?> toJson() => <String, Object?>{
    'unseen': unseen,
    'unread': unread,
    'total': total,
    'version': version,
  };
}

class RealtimePoll {
  const RealtimePoll({required this.events, required this.cursor});

  factory RealtimePoll.fromJson(Map<String, Object?> json) => RealtimePoll(
    events: (json['events'] as List<Object?>)
        .map(
          (Object? e0) => RealtimeEnvelope.fromJson(e0 as Map<String, Object?>),
        )
        .toList(),
    cursor: json['cursor'] as String,
  );

  final List<RealtimeEnvelope> events;

  final String cursor;

  Map<String, Object?> toJson() => <String, Object?>{
    'events': events.map((RealtimeEnvelope e0) => e0.toJson()).toList(),
    'cursor': cursor,
  };
}

class ScopeKeyPreference {
  const ScopeKeyPreference({required this.scopeKey, required this.value});

  factory ScopeKeyPreference.fromJson(Map<String, Object?> json) =>
      ScopeKeyPreference(
        scopeKey: json['scope_key'] as String,
        value: PreferenceValue.fromWire(json['value'] as String),
      );

  final String scopeKey;

  final PreferenceValue value;

  Map<String, Object?> toJson() => <String, Object?>{
    'scope_key': scopeKey,
    'value': value.wire,
  };
}

class SubscriberPreferences {
  const SubscriberPreferences({
    required this.object,
    required this.subscriberId,
    required this.cells,
    required this.channels,
    required this.workflows,
    required this.scopeKeys,
    required this.profile,
  });

  factory SubscriberPreferences.fromJson(Map<String, Object?> json) =>
      SubscriberPreferences(
        object: json['object'] as String,
        subscriberId: json['subscriber_id'] as String,
        cells: (json['cells'] as List<Object?>)
            .map(
              (Object? e0) =>
                  PreferenceCell.fromJson(e0 as Map<String, Object?>),
            )
            .toList(),
        channels: (json['channels'] as List<Object?>)
            .map(
              (Object? e0) =>
                  ChannelPreference.fromJson(e0 as Map<String, Object?>),
            )
            .toList(),
        workflows: (json['workflows'] as List<Object?>)
            .map(
              (Object? e0) =>
                  WorkflowPreference.fromJson(e0 as Map<String, Object?>),
            )
            .toList(),
        scopeKeys: (json['scope_keys'] as List<Object?>)
            .map(
              (Object? e0) =>
                  ScopeKeyPreference.fromJson(e0 as Map<String, Object?>),
            )
            .toList(),
        profile: PreferenceProfile.fromJson(
          json['profile'] as Map<String, Object?>,
        ),
      );

  final String object;

  final String subscriberId;

  final List<PreferenceCell> cells;

  final List<ChannelPreference> channels;

  final List<WorkflowPreference> workflows;

  final List<ScopeKeyPreference> scopeKeys;

  final PreferenceProfile profile;

  Map<String, Object?> toJson() => <String, Object?>{
    'object': object,
    'subscriber_id': subscriberId,
    'cells': cells.map((PreferenceCell e0) => e0.toJson()).toList(),
    'channels': channels.map((ChannelPreference e0) => e0.toJson()).toList(),
    'workflows': workflows.map((WorkflowPreference e0) => e0.toJson()).toList(),
    'scope_keys': scopeKeys
        .map((ScopeKeyPreference e0) => e0.toJson())
        .toList(),
    'profile': profile.toJson(),
  };
}

class TimeRange {
  const TimeRange({required this.day, required this.start, required this.end});

  factory TimeRange.fromJson(Map<String, Object?> json) => TimeRange(
    day: json['day'] as String,
    start: json['start'] as String,
    end: json['end'] as String,
  );

  final String day;

  final String start;

  final String end;

  Map<String, Object?> toJson() => <String, Object?>{
    'day': day,
    'start': start,
    'end': end,
  };
}

class WaitpointResponder {
  const WaitpointResponder({
    required this.recipientId,
    required this.kind,
    this.externalId,
  });

  factory WaitpointResponder.fromJson(Map<String, Object?> json) =>
      WaitpointResponder(
        recipientId: json['recipient_id'] as String,
        kind: json['kind'] as String,
        externalId: json['external_id'] == null
            ? null
            : json['external_id'] as String,
      );

  final String recipientId;

  final String kind;

  final String? externalId;

  Map<String, Object?> toJson() => <String, Object?>{
    'recipient_id': recipientId,
    'kind': kind,
    if (externalId != null) 'external_id': externalId,
  };
}

class WaitpointResponseReceipt {
  const WaitpointResponseReceipt({
    required this.object,
    required this.waitpointId,
    required this.status,
    this.responseId,
    this.responder,
    this.evidenceLevel,
    this.respondedAt,
    this.responseDigest,
    this.ruleId,
  });

  factory WaitpointResponseReceipt.fromJson(Map<String, Object?> json) =>
      WaitpointResponseReceipt(
        object: json['object'] as String,
        waitpointId: json['waitpoint_id'] as String,
        status: json['status'] as String,
        responseId: json['response_id'] == null
            ? null
            : json['response_id'] as String,
        responder: json['responder'] == null
            ? null
            : WaitpointResponder.fromJson(
                json['responder'] as Map<String, Object?>,
              ),
        evidenceLevel: json['evidence_level'] == null
            ? null
            : EvidenceLevel.fromWire(json['evidence_level'] as String),
        respondedAt: json['responded_at'] == null
            ? null
            : json['responded_at'] as String,
        responseDigest: json['response_digest'] == null
            ? null
            : json['response_digest'] as String,
        ruleId: json['rule_id'] == null ? null : json['rule_id'] as String,
      );

  final String object;

  final String waitpointId;

  final String status;

  final String? responseId;

  final WaitpointResponder? responder;

  final EvidenceLevel? evidenceLevel;

  final String? respondedAt;

  final String? responseDigest;

  final String? ruleId;

  Map<String, Object?> toJson() => <String, Object?>{
    'object': object,
    'waitpoint_id': waitpointId,
    'status': status,
    if (responseId != null) 'response_id': responseId,
    if (responder != null) 'responder': responder!.toJson(),
    if (evidenceLevel != null) 'evidence_level': evidenceLevel!.wire,
    if (respondedAt != null) 'responded_at': respondedAt,
    if (responseDigest != null) 'response_digest': responseDigest,
    if (ruleId != null) 'rule_id': ruleId,
  };
}

class WaitpointResponseRequest {
  const WaitpointResponseRequest({
    required this.response,
    required this.subjectDigest,
  });

  factory WaitpointResponseRequest.fromJson(Map<String, Object?> json) =>
      WaitpointResponseRequest(
        response: json['response'],
        subjectDigest: json['subject_digest'] as String,
      );

  final Object? response;

  final String subjectDigest;

  Map<String, Object?> toJson() => <String, Object?>{
    'response': response,
    'subject_digest': subjectDigest,
  };
}

class WebPushKeys {
  const WebPushKeys({required this.p256dh, required this.auth});

  factory WebPushKeys.fromJson(Map<String, Object?> json) => WebPushKeys(
    p256dh: json['p256dh'] as String,
    auth: json['auth'] as String,
  );

  final String p256dh;

  final String auth;

  Map<String, Object?> toJson() => <String, Object?>{
    'p256dh': p256dh,
    'auth': auth,
  };
}

class WorkflowPreference {
  const WorkflowPreference({required this.workflow, required this.value});

  factory WorkflowPreference.fromJson(Map<String, Object?> json) =>
      WorkflowPreference(
        workflow: json['workflow'] as String,
        value: PreferenceValue.fromWire(json['value'] as String),
      );

  final String workflow;

  final PreferenceValue value;

  Map<String, Object?> toJson() => <String, Object?>{
    'workflow': workflow,
    'value': value.wire,
  };
}
