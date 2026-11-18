import 'package:flutter/widgets.dart';

import '../generated/models.dart';
import 'scope.dart';

/// The texts of the Relay widgets, in Turkish and English.
const Map<String, Map<String, String>> relayStrings =
    <String, Map<String, String>>{
      'tr': <String, String>{
        'inbox_title': 'Bildirimler',
        'bell_label': 'Bildirimler, {count} yeni',
        'bell_label_none': 'Bildirimler, yeni yok',
        'badge_overflow': '99+',
        'unread': 'Okunmadı',
        'mark_read': 'Okundu işaretle',
        'mark_unread': 'Okunmadı işaretle',
        'archive': 'Arşivle',
        'hide': 'Gizle',
        'undo': 'Geri al',
        'archived': 'Arşivlendi',
        'hidden': 'Gizlendi',
        'empty_inbox': 'Yeni bildirim yok',
        'load_more': 'Daha fazla göster',
        'mark_all_read': 'Tümünü okundu işaretle',
        'updated_elsewhere': 'Başka bir cihazda güncellendi',
        'error_generic': 'Bir sorun oluştu. Tekrar deneyin.',
        'retry': 'Tekrar dene',
        'preferences_title': 'Bildirim tercihleri',
        'on': 'Açık',
        'off': 'Kapalı',
        'locked_on': 'Açık (kilitli)',
        'os_disabled': 'Cihaz ayarlarından kapalı',
        'last_channel': '{category} için en az bir kanal açık kalmalı.',
        'digest_not_allowed': '{category} için özet seçilemez.',
        'off_step_title': '{category} bildirimleri nasıl gelsin?',
        'off_instant': 'Anında al',
        'off_digest': 'Özet al',
        'off_never': 'Hiç alma',
        'cancel': 'Vazgeç',
        'channel_push': 'Mobil bildirim',
        'channel_web_push': 'Tarayıcı bildirimi',
        'channel_email': 'E-posta',
        'channel_sms': 'SMS',
        'channel_voice': 'Sesli arama',
        'channel_whatsapp': 'WhatsApp',
        'channel_slack': 'Slack',
        'channel_teams': 'Teams',
        'channel_telegram': 'Telegram',
        'channel_discord': 'Discord',
        'channel_in_app': 'Uygulama içi',
        'channel_webhook': 'Webhook',
        'cell_label': '{category}, {channel}: {state}',
      },
      'en': <String, String>{
        'inbox_title': 'Notifications',
        'bell_label': 'Notifications, {count} new',
        'bell_label_none': 'Notifications, none new',
        'badge_overflow': '99+',
        'unread': 'Unread',
        'mark_read': 'Mark as read',
        'mark_unread': 'Mark as unread',
        'archive': 'Archive',
        'hide': 'Hide',
        'undo': 'Undo',
        'archived': 'Archived',
        'hidden': 'Hidden',
        'empty_inbox': 'No new notifications',
        'load_more': 'Show more',
        'mark_all_read': 'Mark all as read',
        'updated_elsewhere': 'Updated on another device',
        'error_generic': 'Something went wrong. Try again.',
        'retry': 'Try again',
        'preferences_title': 'Notification preferences',
        'on': 'On',
        'off': 'Off',
        'locked_on': 'On (locked)',
        'os_disabled': 'Off in device settings',
        'last_channel': 'At least one channel must stay on for {category}.',
        'digest_not_allowed': 'A digest cannot be chosen for {category}.',
        'off_step_title': 'How should {category} notifications arrive?',
        'off_instant': 'Get them instantly',
        'off_digest': 'Get a digest',
        'off_never': 'Never get them',
        'cancel': 'Cancel',
        'channel_push': 'Mobile notification',
        'channel_web_push': 'Browser notification',
        'channel_email': 'Email',
        'channel_sms': 'SMS',
        'channel_voice': 'Voice call',
        'channel_whatsapp': 'WhatsApp',
        'channel_slack': 'Slack',
        'channel_teams': 'Teams',
        'channel_telegram': 'Telegram',
        'channel_discord': 'Discord',
        'channel_in_app': 'In-app',
        'channel_webhook': 'Webhook',
        'cell_label': '{category}, {channel}: {state}',
      },
    };

// X-32
/// Looks up widget texts for a locale: Turkish for tr, English otherwise.
class RelayLocalizations {
  /// Creates the lookup.
  const RelayLocalizations(this.language);

  /// The language code in use.
  final String language;

  /// The lookup for a locale.
  factory RelayLocalizations.forLocale(Locale? locale) =>
      RelayLocalizations(locale?.languageCode == 'tr' ? 'tr' : 'en');

  /// The lookup for the ambient locale.
  static RelayLocalizations of(BuildContext context) =>
      RelayLocalizations.forLocale(
        RelayScope.maybeOf(context)?.locale ??
            Localizations.maybeLocaleOf(context),
      );

  /// A text with its placeholders filled.
  String text(
    String key, [
    Map<String, String> args = const <String, String>{},
  ]) {
    String value =
        relayStrings[language]![key] ?? relayStrings['en']![key] ?? key;
    args.forEach((String k, String v) {
      value = value.replaceAll('{$k}', v);
    });
    return value;
  }

  /// The badge text of a count.
  String badge(int count) => count > 99 ? text('badge_overflow') : '$count';

  /// The name of a channel.
  String channel(Channel channel) => text('channel_${channel.wire}');
}
