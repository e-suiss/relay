import '../generated/models.dart';

/// The message class of a category.
enum RelayMessageClass {
  /// Security.
  security('security'),

  /// Action required.
  actionRequired('action_required'),

  /// Transactional.
  transactional('transactional'),

  /// Operational.
  operational('operational'),

  /// Social.
  social('social'),

  /// Marketing.
  marketing('marketing'),

  /// System; never visible.
  system('system');

  const RelayMessageClass(this.wire);

  /// The wire name.
  final String wire;

  /// The class of a wire name.
  static RelayMessageClass fromWire(String value) =>
      RelayMessageClass.values.firstWhere(
        (RelayMessageClass c) => c.wire == value,
        orElse: () => throw ArgumentError.value(value, 'class'),
      );
}

/// The interruption level of a notification.
enum RelayInterruptionLevel {
  /// Silent.
  passive('passive'),

  /// Normal.
  active('active'),

  /// Breaks through focus where the platform allows.
  timeSensitive('time-sensitive'),

  /// Breaks through silent mode; needs the user's grant.
  critical('critical');

  const RelayInterruptionLevel(this.wire);

  /// The wire name used in channel ids.
  final String wire;
}

/// A notification category the app declares to the SDK.
class RelayCategory {
  /// Creates a category.
  const RelayCategory(
    this.key,
    this.messageClass, {
    this.critical = false,
    this.name,
  });

  /// The tenant's category key.
  final String key;

  /// The category's message class.
  final RelayMessageClass messageClass;

  /// Whether the category is declared for critical alerts.
  final bool critical;

  /// The user-visible channel name, when the app supplies one.
  final String? name;
}

/// An Android notification channel the SDK creates.
class RelayAndroidChannel {
  /// Creates a channel description.
  const RelayAndroidChannel({
    required this.id,
    required this.category,
    required this.level,
    required this.importance,
    required this.bypassDnd,
  });

  /// The stable channel id `relay.<category>.<level>`.
  final String id;

  /// The category key.
  final String category;

  /// The interruption level.
  final RelayInterruptionLevel level;

  /// The importance the channel is created with.
  final AndroidChannelImportance importance;

  /// Whether the channel bypasses Do Not Disturb.
  final bool bypassDnd;
}

final RegExp _categoryKey = RegExp(r'^[a-z][a-z0-9_]{0,47}$');

RelayInterruptionLevel? _ceiling(RelayMessageClass c) {
  switch (c) {
    case RelayMessageClass.security:
    case RelayMessageClass.actionRequired:
    case RelayMessageClass.transactional:
      return RelayInterruptionLevel.timeSensitive;
    case RelayMessageClass.operational:
    case RelayMessageClass.social:
      return RelayInterruptionLevel.active;
    case RelayMessageClass.marketing:
      return RelayInterruptionLevel.passive;
    case RelayMessageClass.system:
      return null;
  }
}

AndroidChannelImportance _importance(
  RelayMessageClass c,
  RelayInterruptionLevel level,
) {
  switch (level) {
    case RelayInterruptionLevel.passive:
      return AndroidChannelImportance.low;
    case RelayInterruptionLevel.active:
      return c == RelayMessageClass.social || c == RelayMessageClass.marketing
          ? AndroidChannelImportance.low
          : AndroidChannelImportance.defaultValue;
    case RelayInterruptionLevel.timeSensitive:
    case RelayInterruptionLevel.critical:
      return AndroidChannelImportance.high;
  }
}

// CH-30
// CH-65
// CH-68
/// The Android channels for the categories; ids stay the same across app versions.
List<RelayAndroidChannel> relayAndroidChannels(List<RelayCategory> categories) {
  final List<RelayAndroidChannel> out = <RelayAndroidChannel>[];
  for (final RelayCategory c in categories) {
    if (!_categoryKey.hasMatch(c.key)) {
      throw ArgumentError.value(c.key, 'key', 'not a channel category key');
    }
    final RelayInterruptionLevel? ceiling = _ceiling(c.messageClass);
    if (ceiling == null) continue;
    final List<RelayInterruptionLevel> levels = <RelayInterruptionLevel>[
      for (final RelayInterruptionLevel l in RelayInterruptionLevel.values)
        if (l != RelayInterruptionLevel.critical && l.index <= ceiling.index) l,
      if (c.critical) RelayInterruptionLevel.critical,
    ];
    for (final RelayInterruptionLevel l in levels) {
      out.add(
        RelayAndroidChannel(
          id: 'relay.${c.key}.${l.wire}',
          category: c.key,
          level: l,
          importance: _importance(c.messageClass, l),
          bypassDnd: l == RelayInterruptionLevel.critical,
        ),
      );
    }
  }
  return out;
}

// CH-29
/// Whether to ask for iOS provisional authorisation: only when every class the app starts with is marketing or social.
bool relayUseProvisional(Iterable<RelayMessageClass> classes) =>
    classes.isNotEmpty &&
    classes.every(
      (RelayMessageClass c) =>
          c == RelayMessageClass.marketing || c == RelayMessageClass.social,
    );
