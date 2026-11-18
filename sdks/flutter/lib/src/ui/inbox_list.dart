import 'dart:async';

import 'package:flutter/material.dart';

import '../client.dart';
import '../generated/models.dart';
import '../inbox/offline_queue.dart';
import 'l10n.dart';
import 'scope.dart';
import 'theme.dart';

// X-32
// IN-12
// IN-15
/// The inbox list: read, unread, archive and hide with undo; unread items carry a text label, never colour alone.
class RelayInboxList extends StatefulWidget {
  /// Creates the list.
  const RelayInboxList({super.key, this.onItemTap});

  /// Called when the user opens an item.
  final void Function(InboxItem item)? onItemTap;

  @override
  State<RelayInboxList> createState() => _RelayInboxListState();
}

class _RelayInboxListState extends State<RelayInboxList> {
  final Set<String> _pending = <String>{};
  StreamSubscription<RelayConflictNotice>? _notices;
  RelayClient? _client;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final RelayClient client = RelayScope.of(context);
    if (!identical(client, _client)) {
      unawaited(_notices?.cancel());
      _client = client;
      _notices = client.intents.notices.listen((RelayConflictNotice _) {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              RelayLocalizations.of(context).text('updated_elsewhere'),
            ),
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    unawaited(_notices?.cancel());
    super.dispose();
  }

  void _remove(RelayClient client, InboxItem item, String op) {
    final RelayLocalizations l10n = RelayLocalizations.of(context);
    setState(() => _pending.add(item.id));
    client.undo.schedule(item.id, () async {
      if (mounted) setState(() => _pending.remove(item.id));
      await client.intent(item.id, op);
    });
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(l10n.text(op == 'archive' ? 'archived' : 'hidden')),
        action: SnackBarAction(
          label: l10n.text('undo'),
          onPressed: () {
            if (client.undo.undo(item.id) && mounted) {
              setState(() => _pending.remove(item.id));
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final RelayClient client = RelayScope.of(context);
    final RelayThemeData theme = RelayThemeData.of(context);
    final RelayLocalizations l10n = RelayLocalizations.of(context);
    return ListenableBuilder(
      listenable: client.inbox,
      builder: (BuildContext context, Widget? _) {
        final List<InboxItem> items = client.inbox.items
            .where((InboxItem i) => !_pending.contains(i.id))
            .toList();
        if (items.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                l10n.text('empty_inbox'),
                style: TextStyle(color: theme.onSurfaceMuted, fontSize: 16),
              ),
            ),
          );
        }
        return Material(
          color: theme.surface,
          child: ListView.separated(
            itemCount: items.length + (client.inbox.hasMore ? 1 : 0),
            separatorBuilder: (BuildContext context, int index) =>
                Divider(height: 1, color: theme.divider),
            itemBuilder: (BuildContext context, int index) {
              if (index == items.length) {
                return Center(
                  child: TextButton(
                    onPressed: () => unawaited(client.sync.loadMore()),
                    child: Text(
                      l10n.text('load_more'),
                      style: TextStyle(color: theme.accent),
                    ),
                  ),
                );
              }
              return _RelayInboxRow(
                item: items[index],
                theme: theme,
                l10n: l10n,
                onTap: () {
                  final InboxItem item = items[index];
                  unawaited(client.intent(item.id, 'read'));
                  widget.onItemTap?.call(item);
                },
                onToggleRead: () {
                  final InboxItem item = items[index];
                  unawaited(
                    client.intent(item.id, item.read ? 'unread' : 'read'),
                  );
                },
                onArchive: () => _remove(client, items[index], 'archive'),
                onHide: () => _remove(client, items[index], 'hide'),
              );
            },
          ),
        );
      },
    );
  }
}

class _RelayInboxRow extends StatelessWidget {
  const _RelayInboxRow({
    required this.item,
    required this.theme,
    required this.l10n,
    required this.onTap,
    required this.onToggleRead,
    required this.onArchive,
    required this.onHide,
  });

  final InboxItem item;
  final RelayThemeData theme;
  final RelayLocalizations l10n;
  final VoidCallback onTap;
  final VoidCallback onToggleRead;
  final VoidCallback onArchive;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final bool unread = !item.read;
    final TextDirection? dir = switch (item.dir) {
      'rtl' => TextDirection.rtl,
      'ltr' => TextDirection.ltr,
      _ => null,
    };
    final Widget content = Semantics(
      button: true,
      label: <String>[
        if (unread) l10n.text('unread'),
        if (item.title != null) item.title!,
        if (item.body != null) item.body!,
      ].join('. '),
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 6, right: 12),
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: unread ? theme.unread : const Color(0x00000000),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (unread)
                        Text(
                          l10n.text('unread'),
                          style: TextStyle(
                            color: theme.accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      if (item.title != null)
                        Text(
                          item.title!,
                          textDirection: dir,
                          style: TextStyle(
                            color: theme.onSurface,
                            fontSize: 16,
                            fontWeight: unread
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      if (item.body != null)
                        Text(
                          item.body!,
                          textDirection: dir,
                          style: TextStyle(
                            color: theme.onSurfaceMuted,
                            fontSize: 14,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Row(
      children: <Widget>[
        Expanded(child: content),
        IconButton(
          tooltip: l10n.text(unread ? 'mark_read' : 'mark_unread'),
          color: theme.onSurface,
          icon: Icon(
            unread
                ? Icons.mark_email_read_outlined
                : Icons.mark_email_unread_outlined,
          ),
          onPressed: onToggleRead,
        ),
        IconButton(
          tooltip: l10n.text('archive'),
          color: theme.onSurface,
          icon: const Icon(Icons.archive_outlined),
          onPressed: onArchive,
        ),
        IconButton(
          tooltip: l10n.text('hide'),
          color: theme.onSurface,
          icon: const Icon(Icons.visibility_off_outlined),
          onPressed: onHide,
        ),
      ],
    );
  }
}
