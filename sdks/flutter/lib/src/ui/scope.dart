import 'package:flutter/widgets.dart';

import '../client.dart';

/// Provides a [RelayClient] and, optionally, the widget language to the Relay widgets below it.
class RelayScope extends InheritedWidget {
  /// Creates the scope.
  const RelayScope({
    super.key,
    required this.client,
    this.locale,
    required super.child,
  });

  /// The client.
  final RelayClient client;

  /// The language of the widgets; the ambient locale when null.
  final Locale? locale;

  /// The nearest scope, if any.
  static RelayScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RelayScope>();

  /// The nearest client.
  static RelayClient of(BuildContext context) {
    final RelayScope? scope = maybeOf(context);
    assert(scope != null, 'No RelayScope above this widget');
    return scope!.client;
  }

  @override
  bool updateShouldNotify(RelayScope oldWidget) =>
      client != oldWidget.client || locale != oldWidget.locale;
}
