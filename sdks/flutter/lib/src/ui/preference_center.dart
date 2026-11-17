import 'dart:async';

import 'package:flutter/material.dart';

import '../client.dart';
import '../core/errors.dart';
import '../generated/models.dart';
import 'l10n.dart';
import 'scope.dart';
import 'theme.dart';

enum _OffChoice { instant, digest, never }

// X-32
// X-18
// X-20
// PC-17
/// The preference center: category by channel switches, locked cells shown as such, push shown off when the device disallows it, and a three-way step without a preselected choice when a category is turned off.
class RelayPreferenceCenter extends StatefulWidget {
  /// Creates the preference center.
  const RelayPreferenceCenter({
    super.key,
    this.categoryLabels = const <String, String>{},
  });

  /// Display names of category keys.
  final Map<String, String> categoryLabels;

  @override
  State<RelayPreferenceCenter> createState() => _RelayPreferenceCenterState();
}

class _RelayPreferenceCenterState extends State<RelayPreferenceCenter> {
  SubscriberPreferences? _prefs;
  bool _failed = false;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prefs == null && !_failed) unawaited(_load());
  }

  Future<void> _load() async {
    final RelayClient client = RelayScope.of(context);
    try {
      final SubscriberPreferences prefs = await client.preferences.get();
      if (mounted) setState(() => _prefs = prefs);
    } on RelayError {
      if (mounted) setState(() => _failed = true);
    }
  }

  String _label(String category) => widget.categoryLabels[category] ?? category;

  Future<void> _write(
    Future<SubscriberPreferences> Function() write,
    String category,
  ) async {
    final RelayLocalizations l10n = RelayLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final SubscriberPreferences prefs = await write();
      if (mounted) setState(() => _prefs = prefs);
    } on RelayError catch (error) {
      if (!mounted) return;
      final String key = switch (error.code) {
        'preference_last_channel' => 'last_channel',
        'preference_digest_not_allowed' => 'digest_not_allowed',
        _ => 'error_generic',
      };
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            l10n.text(key, <String, String>{'category': _label(category)}),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(PreferenceCell cell, bool on) async {
    final RelayClient client = RelayScope.of(context);
    final SubscriberPreferences current = _prefs!;
    if (on) {
      await _write(
        () => client.preferences.setCell(
          cell.category,
          cell.channel,
          PreferenceValue.optIn,
        ),
        cell.category,
      );
      return;
    }
    final _OffChoice? choice = await showDialog<_OffChoice>(
      context: context,
      builder: (BuildContext _) => _OffStep(
        category: _label(cell.category),
        l10n: RelayLocalizations.of(context),
        theme: RelayThemeData.of(context),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case null:
      case _OffChoice.instant:
        return;
      case _OffChoice.digest:
        await _write(
          () => client.preferences.setDigest(current, cell.category, 'digest'),
          cell.category,
        );
      case _OffChoice.never:
        await _write(
          () => client.preferences.setCell(
            cell.category,
            cell.channel,
            PreferenceValue.optOut,
          ),
          cell.category,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final RelayClient client = RelayScope.of(context);
    final RelayThemeData theme = RelayThemeData.of(context);
    final RelayLocalizations l10n = RelayLocalizations.of(context);
    final SubscriberPreferences? prefs = _prefs;
    if (_failed) {
      return Center(
        child: TextButton(
          onPressed: () {
            setState(() => _failed = false);
            unawaited(_load());
          },
          child: Text(
            l10n.text('retry'),
            style: TextStyle(color: theme.accent),
          ),
        ),
      );
    }
    if (prefs == null) return const Center(child: CircularProgressIndicator());
    final Map<String, List<PreferenceCell>> byCategory =
        <String, List<PreferenceCell>>{};
    for (final PreferenceCell c in prefs.cells) {
      byCategory.putIfAbsent(c.category, () => <PreferenceCell>[]).add(c);
    }
    final bool osDisabled = client.pushPermission == DevicePermission.denied;
    return ColoredBox(
      color: theme.surface,
      child: ListView(
        children: <Widget>[
          for (final MapEntry<String, List<PreferenceCell>> entry
              in byCategory.entries) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Semantics(
                header: true,
                child: Text(
                  _label(entry.key),
                  style: TextStyle(
                    color: theme.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            for (final PreferenceCell cell in entry.value)
              _cell(
                cell,
                theme,
                l10n,
                osDisabled && cell.channel == Channel.push,
              ),
          ],
        ],
      ),
    );
  }

  Widget _cell(
    PreferenceCell cell,
    RelayThemeData theme,
    RelayLocalizations l10n,
    bool osDisabled,
  ) {
    final String channel = l10n.channel(cell.channel);
    if (cell.source == PreferenceSource.locked) {
      return Semantics(
        label: l10n.text('cell_label', <String, String>{
          'category': _label(cell.category),
          'channel': channel,
          'state': l10n.text('locked_on'),
        }),
        excludeSemantics: true,
        child: ListTile(
          minTileHeight: 48,
          title: Text(channel, style: TextStyle(color: theme.onSurface)),
          trailing: Text(
            l10n.text('locked_on'),
            style: TextStyle(color: theme.onSurfaceMuted),
          ),
        ),
      );
    }
    return SwitchListTile(
      value: cell.effective,
      onChanged: _busy ? null : (bool on) => unawaited(_toggle(cell, on)),
      activeTrackColor: theme.accent,
      title: Text(channel, style: TextStyle(color: theme.onSurface)),
      subtitle: Text(
        osDisabled
            ? l10n.text('os_disabled')
            : l10n.text(cell.effective ? 'on' : 'off'),
        style: TextStyle(
          color: osDisabled ? theme.danger : theme.onSurfaceMuted,
        ),
      ),
    );
  }
}

class _OffStep extends StatelessWidget {
  const _OffStep({
    required this.category,
    required this.l10n,
    required this.theme,
  });

  final String category;

  final RelayLocalizations l10n;

  final RelayThemeData theme;

  @override
  Widget build(BuildContext context) {
    Widget option(_OffChoice choice, String key) => SimpleDialogOption(
      onPressed: () => Navigator.of(context).pop(choice),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            l10n.text(key),
            style: TextStyle(color: theme.onSurface, fontSize: 16),
          ),
        ),
      ),
    );
    return SimpleDialog(
      title: Text(
        l10n.text('off_step_title', <String, String>{'category': category}),
      ),
      children: <Widget>[
        option(_OffChoice.instant, 'off_instant'),
        option(_OffChoice.digest, 'off_digest'),
        option(_OffChoice.never, 'off_never'),
      ],
    );
  }
}
