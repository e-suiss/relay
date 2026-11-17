import 'package:flutter/material.dart';

import '../inbox/store.dart';
import 'l10n.dart';
import 'scope.dart';
import 'theme.dart';

// X-32
// IN-19
/// A bell with the unseen badge; the badge never relies on colour alone, its count is in the label.
class RelayInboxBell extends StatelessWidget {
  /// Creates the bell.
  const RelayInboxBell({super.key, required this.onPressed, this.store});

  /// Opens the inbox.
  final VoidCallback onPressed;

  /// The inbox to show; defaults to the scope's client.
  final RelayInboxStore? store;

  @override
  Widget build(BuildContext context) {
    final RelayInboxStore inbox = store ?? RelayScope.of(context).inbox;
    final RelayThemeData theme = RelayThemeData.of(context);
    final RelayLocalizations l10n = RelayLocalizations.of(context);
    return ListenableBuilder(
      listenable: inbox,
      builder: (BuildContext context, Widget? _) {
        final int count = inbox.unseen;
        final String label = count > 0
            ? l10n.text('bell_label', <String, String>{'count': l10n.badge(count)})
            : l10n.text('bell_label_none');
        return Semantics(
          button: true,
          label: label,
          onTap: onPressed,
          excludeSemantics: true,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: InkResponse(
              onTap: onPressed,
              radius: 24,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: <Widget>[
                  Icon(Icons.notifications_outlined, color: theme.onSurface),
                  if (count > 0)
                    Positioned(
                      top: 6,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        constraints: const BoxConstraints(minWidth: 18),
                        decoration: BoxDecoration(
                          color: theme.badge,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          l10n.badge(count),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: theme.onBadge,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
