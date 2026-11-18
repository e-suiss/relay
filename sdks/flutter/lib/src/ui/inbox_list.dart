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
// IN-6
// AG-34
// AG-35
/// The inbox list: read, unread, archive and hide with undo; unread items carry a text label, never colour alone; agent items say so; an item awaiting a response shows its options and then its state; an approval item only links to the Access approval surface.
class RelayInboxList extends StatefulWidget {
  /// Creates the list.
  const RelayInboxList({super.key, this.onItemTap, this.onOpenUrl});

  /// Called when the user opens an item.
  final void Function(InboxItem item)? onItemTap;

  /// Opens a link, such as the Access approval surface of an approval item; no link is shown when null.
  final ValueChanged<Uri>? onOpenUrl;

  @override
  State<RelayInboxList> createState() => _RelayInboxListState();
}

class _RelayInboxListState extends State<RelayInboxList> {
  final Set<String> _pending = <String>{};
  final Set<String> _responding = <String>{};
  final Map<String, WaitpointResponseReceipt> _receipts =
      <String, WaitpointResponseReceipt>{};
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

  Future<void> _respond(
    RelayClient client,
    InboxWaitpoint waitpoint,
    String value,
  ) async {
    final String? digest = waitpoint.subjectDigest;
    if (digest == null || _responding.contains(waitpoint.id)) return;
    final RelayLocalizations l10n = RelayLocalizations.of(context);
    setState(() => _responding.add(waitpoint.id));
    try {
      final WaitpointResponseReceipt receipt = await client.waitpoints.respond(
        waitpoint.id,
        value,
        subjectDigest: digest,
      );
      if (mounted) setState(() => _receipts[waitpoint.id] = receipt);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(l10n.text('error_generic'))),
        );
      }
    } finally {
      if (mounted) setState(() => _responding.remove(waitpoint.id));
    }
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
              final InboxWaitpoint? waitpoint = items[index].waitpoint;
              return _RelayInboxRow(
                item: items[index],
                theme: theme,
                l10n: l10n,
                responding:
                    waitpoint != null && _responding.contains(waitpoint.id),
                receipt: waitpoint == null ? null : _receipts[waitpoint.id],
                onRespond: waitpoint == null
                    ? null
                    : (String value) =>
                          unawaited(_respond(client, waitpoint, value)),
                onOpenUrl: widget.onOpenUrl,
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
    required this.responding,
    required this.receipt,
    required this.onRespond,
    required this.onOpenUrl,
    required this.onTap,
    required this.onToggleRead,
    required this.onArchive,
    required this.onHide,
  });

  final InboxItem item;
  final RelayThemeData theme;
  final RelayLocalizations l10n;
  final bool responding;
  final WaitpointResponseReceipt? receipt;
  final ValueChanged<String>? onRespond;
  final ValueChanged<Uri>? onOpenUrl;
  final VoidCallback onTap;
  final VoidCallback onToggleRead;
  final VoidCallback onArchive;
  final VoidCallback onHide;

  bool get _approval =>
      item.approval == true || item.waitpoint?.kind == 'approval';

  String get _status {
    if (responding) return 'processing';
    return receipt?.status ?? item.waitpoint?.status ?? 'awaiting';
  }

  Uri? get _approvalUrl {
    final String? raw =
        item.waitpoint?.approvalUrl ??
        (item.actions.isEmpty ? null : item.actions.first.url);
    if (raw == null) return null;
    final Uri? uri = Uri.tryParse(raw);
    return uri != null && (uri.scheme == 'https' || uri.scheme == 'http')
        ? uri
        : null;
  }

  String _when(BuildContext context, String? at) {
    final DateTime? time = at == null ? null : DateTime.tryParse(at);
    if (time == null) return '';
    final DateTime local = time.toLocal();
    final MaterialLocalizations m = MaterialLocalizations.of(context);
    final String clock = m.formatTimeOfDay(
      TimeOfDay.fromDateTime(local),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return '${m.formatMediumDate(local)} $clock';
  }

  String? _stateText(BuildContext context) {
    final InboxWaitpoint? waitpoint = item.waitpoint;
    if (_approval) {
      if (waitpoint == null || waitpoint.status == 'awaiting') {
        return l10n.text('approval_note');
      }
    } else if (waitpoint == null) {
      return null;
    }
    switch (_status) {
      case 'awaiting':
        return l10n.text('waitpoint_awaiting');
      case 'processing':
        return l10n.text('waitpoint_processing');
      case 'responded':
        final WaitpointResponseReceipt? own = receipt;
        final String who = own != null
            ? l10n.text('who_you')
            : waitpoint.responder?.kind == 'agent'
            ? l10n.text('who_agent')
            : l10n.text('who_someone');
        return l10n.text('waitpoint_responded', <String, String>{
          'who': who,
          'when': _when(context, own?.respondedAt ?? waitpoint.respondedAt),
        });
      case 'not_awaited':
        return l10n.text('waitpoint_not_awaited');
    }
    return null;
  }

  Widget? _panel(String? state) {
    if (state == null) return null;
    final InboxWaitpoint? waitpoint = item.waitpoint;
    final List<Widget> actions = <Widget>[];
    final ValueChanged<Uri>? open = onOpenUrl;
    final ValueChanged<String>? respond = onRespond;
    final ButtonStyle style = OutlinedButton.styleFrom(
      minimumSize: const Size(48, 48),
      foregroundColor: theme.accent,
    );
    if (_approval) {
      final Uri? url = _approvalUrl;
      if (url != null &&
          open != null &&
          (waitpoint == null || waitpoint.status == 'awaiting')) {
        actions.add(
          OutlinedButton(
            style: style,
            onPressed: () => open(url),
            child: Text(l10n.text('approval_open')),
          ),
        );
      }
    } else if (waitpoint != null &&
        _status == 'awaiting' &&
        waitpoint.subjectDigest != null &&
        respond != null) {
      for (final InboxWaitpointOptionsItem option in waitpoint.options) {
        actions.add(
          OutlinedButton(
            style: style,
            onPressed: () => respond(option.value),
            child: Text(option.label),
          ),
        );
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            liveRegion: true,
            child: Text(
              state,
              style: TextStyle(color: theme.onSurfaceMuted, fontSize: 14),
            ),
          ),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(spacing: 8, runSpacing: 8, children: actions),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool unread = !item.read;
    final bool agent = item.senderType == 'agent';
    final String? state = _stateText(context);
    final TextDirection? dir = switch (item.dir) {
      'rtl' => TextDirection.rtl,
      'ltr' => TextDirection.ltr,
      _ => null,
    };
    final Widget content = Semantics(
      button: true,
      label: <String>[
        if (unread) l10n.text('unread'),
        if (agent) l10n.text('sender_agent'),
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
                      if (agent)
                        Text(
                          l10n.text('sender_agent'),
                          style: TextStyle(
                            color: theme.onSurfaceMuted,
                            fontSize: 12,
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
    final Widget? panel = _panel(state);
    final Widget row = Row(
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
    if (panel == null) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[row, panel],
    );
  }
}
