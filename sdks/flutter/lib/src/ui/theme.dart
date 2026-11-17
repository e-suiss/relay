
import 'package:flutter/material.dart';

// X-32
/// Colours and shapes of the Relay widgets; light and dark defaults meet WCAG 2.2 AA contrast, and a brand (tenant or subtenant) can replace the accent.
@immutable
class RelayThemeData extends ThemeExtension<RelayThemeData> {
  /// Creates a theme.
  const RelayThemeData({
    required this.surface,
    required this.onSurface,
    required this.onSurfaceMuted,
    required this.accent,
    required this.onAccent,
    required this.badge,
    required this.onBadge,
    required this.unread,
    required this.danger,
    required this.divider,
    this.radius = 12,
  });

  /// The light default.
  const RelayThemeData.light()
      : surface = const Color(0xFFFFFFFF),
        onSurface = const Color(0xFF1B1F24),
        onSurfaceMuted = const Color(0xFF545D68),
        accent = const Color(0xFF0B5CAD),
        onAccent = const Color(0xFFFFFFFF),
        badge = const Color(0xFFB3261E),
        onBadge = const Color(0xFFFFFFFF),
        unread = const Color(0xFF0B5CAD),
        danger = const Color(0xFFB3261E),
        divider = const Color(0xFFD0D7DE),
        radius = 12;

  /// The dark default.
  const RelayThemeData.dark()
      : surface = const Color(0xFF121417),
        onSurface = const Color(0xFFE8EAED),
        onSurfaceMuted = const Color(0xFFADB5BD),
        accent = const Color(0xFF8AB4F8),
        onAccent = const Color(0xFF0B1A2E),
        badge = const Color(0xFFF2B8B5),
        onBadge = const Color(0xFF3C0D0A),
        unread = const Color(0xFF8AB4F8),
        danger = const Color(0xFFF2B8B5),
        divider = const Color(0xFF3A3F45),
        radius = 12;

  /// The background of lists and sheets.
  final Color surface;

  /// Text on [surface].
  final Color onSurface;

  /// Secondary text on [surface].
  final Color onSurfaceMuted;

  /// Brand accent.
  final Color accent;

  /// Text on [accent].
  final Color onAccent;

  /// Badge background.
  final Color badge;

  /// Badge text.
  final Color onBadge;

  /// The unread marker.
  final Color unread;

  /// Errors.
  final Color danger;

  /// Separators.
  final Color divider;

  /// Corner radius.
  final double radius;

  /// The theme in effect: the extension of the ambient [Theme], else the default for its brightness.
  static RelayThemeData of(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return theme.extension<RelayThemeData>() ??
        (theme.brightness == Brightness.dark
            ? const RelayThemeData.dark()
            : const RelayThemeData.light());
  }

  /// Applies a brand accent.
  RelayThemeData withBrand({required Color accent, required Color onAccent}) =>
      copyWith(accent: accent, onAccent: onAccent, unread: accent);

  @override
  RelayThemeData copyWith({
    Color? surface,
    Color? onSurface,
    Color? onSurfaceMuted,
    Color? accent,
    Color? onAccent,
    Color? badge,
    Color? onBadge,
    Color? unread,
    Color? danger,
    Color? divider,
    double? radius,
  }) =>
      RelayThemeData(
        surface: surface ?? this.surface,
        onSurface: onSurface ?? this.onSurface,
        onSurfaceMuted: onSurfaceMuted ?? this.onSurfaceMuted,
        accent: accent ?? this.accent,
        onAccent: onAccent ?? this.onAccent,
        badge: badge ?? this.badge,
        onBadge: onBadge ?? this.onBadge,
        unread: unread ?? this.unread,
        danger: danger ?? this.danger,
        divider: divider ?? this.divider,
        radius: radius ?? this.radius,
      );

  @override
  RelayThemeData lerp(covariant RelayThemeData? other, double t) {
    if (other == null) return this;
    return RelayThemeData(
      surface: Color.lerp(surface, other.surface, t)!,
      onSurface: Color.lerp(onSurface, other.onSurface, t)!,
      onSurfaceMuted: Color.lerp(onSurfaceMuted, other.onSurfaceMuted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      badge: Color.lerp(badge, other.badge, t)!,
      onBadge: Color.lerp(onBadge, other.onBadge, t)!,
      unread: Color.lerp(unread, other.unread, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      radius: radius + (other.radius - radius) * t,
    );
  }
}

/// The WCAG contrast ratio of two colours.
double relayContrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}
