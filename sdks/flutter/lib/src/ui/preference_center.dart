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
// X-44
// PC-59
/// The preference center: category by channel switches, locked cells shown as such, push shown off when the device disallows it, a three-way step without a preselected choice when a category is turned off, and the consents read-only with an optional link to change them in Access.
class RelayPreferenceCenter extends StatefulWidget {
  /// Creates the preference center.
  const RelayPreferenceCenter({
    super.key,
    this.categoryLabels = const <String, String>{},
    this.brandLabels = const <String, String>{},
    this.accessConsentUrl,
    this.onOpenUrl,
  });

  /// Display names of category keys.
  final Map<String, String> categoryLabels;

  /// Display names of the brands (sub-tenant ids) of consents.
  final Map<String, String> brandLabels;

  /// The Access page where the subscriber changes consents; no link is shown when null.
  final Uri? accessConsentUrl;

  /// Opens a link, such as [accessConsentUrl]; no link is shown when null.
  final ValueChanged<Uri>? onOpenUrl;

  @override
  State<RelayPreferenceCenter> createState() => _RelayPreferenceCenterState();
}

class _RelayPreferenceCenterState extends State<RelayPreferenceCenter> {
  SubscriberPreferences? _prefs;
  bool _failed = false;
  bool _busy = false;
  List<Consent>? _consents;
  bool _consentsFailed = false;
  bool _consentsStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prefs == null && !_failed) unawaited(_load());
    if (!_consentsStarted) {
      _consentsStarted = true;
      unawaited(_loadConsents());
    }
  }

  Future<void> _loadConsents() async {
    final RelayClient client = RelayScope.of(context);
    try {
      final List<Consent> consents = await client.preferences.allConsents();
      if (mounted) setState(() => _consents = consents);
    } on Object {
      if (mounted) setState(() => _consentsFailed = true);
    }
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
    return Material(
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
          ..._consentSection(theme, l10n),
        ],
      ),
    );
  }

  List<Widget> _consentSection(RelayThemeData theme, RelayLocalizations l10n) {
    final List<Consent>? loaded = _consents;
    if (loaded == null && !_consentsFailed) return const <Widget>[];
    final List<Consent> consents = <Consent>[
      for (final Consent c in loaded ?? const <Consent>[])
        if (c.status != ConsentStatus.unrecognized &&
            c.channel != Channel.unrecognized)
          c,
    ];
    final Uri? link = widget.accessConsentUrl;
    final ValueChanged<Uri>? open = widget.onOpenUrl;
    final bool linked = link != null && open != null;
    if (consents.isEmpty && !_consentsFailed && !linked) {
      return const <Widget>[];
    }
    return <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 28, 16, 4),
        child: Semantics(
          header: true,
          child: Text(
            l10n.text('consents_title'),
            style: TextStyle(
              color: theme.onSurface,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          l10n.text(_consentsFailed ? 'consents_unavailable' : 'consents_hint'),
          style: TextStyle(color: theme.onSurfaceMuted, fontSize: 14),
        ),
      ),
      for (final Consent c in consents) _consent(c, theme, l10n),
      if (link != null && open != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => open(link),
              child: Text(
                l10n.text('manage_consents'),
                style: TextStyle(color: theme.accent),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _consent(Consent c, RelayThemeData theme, RelayLocalizations l10n) {
    final String channel = l10n.channel(c.channel);
    final String status = l10n.consentStatus(c.status);
    final String? brandId = c.brand;
    final String? brand = brandId == null
        ? null
        : widget.brandLabels[brandId] ?? brandId;
    return Semantics(
      label: brand == null
          ? l10n.text('consent_label', <String, String>{
              'channel': channel,
              'status': status,
            })
          : l10n.text('consent_brand_label', <String, String>{
              'brand': brand,
              'channel': channel,
              'status': status,
            }),
      excludeSemantics: true,
      child: ListTile(
        minTileHeight: 48,
        title: Text(channel, style: TextStyle(color: theme.onSurface)),
        subtitle: brand == null
            ? null
            : Text(brand, style: TextStyle(color: theme.onSurfaceMuted)),
        trailing: Text(status, style: TextStyle(color: theme.onSurfaceMuted)),
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
