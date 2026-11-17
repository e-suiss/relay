export type RelayLocale = 'tr' | 'en';

export const MESSAGES = {
  tr: {
    'push.fallback.title': 'Yeni bildirim',
    'push.fallback.body': 'Yeni bir bildiriminiz var.',
    'inbox.title': 'Bildirimler',
    'inbox.bell': 'Bildirimler, {count} görülmemiş',
    'inbox.bell.none': 'Bildirimler, görülmemiş yok',
    'inbox.empty': 'Henüz bildiriminiz yok.',
    'inbox.loading': 'Bildirimler yükleniyor',
    'inbox.offline': 'Çevrimdışı. Değişiklikleriniz bağlantı gelince gönderilecek.',
    'inbox.unread': 'Okunmadı',
    'inbox.read': 'Okundu',
    'inbox.markRead': 'Okundu olarak işaretle',
    'inbox.markUnread': 'Okunmadı olarak işaretle',
    'inbox.archive': 'Arşivle',
    'inbox.unarchive': 'Arşivden çıkar',
    'inbox.hide': 'Gizle',
    'inbox.readAll': 'Tümünü okundu yap',
    'inbox.undo': 'Geri al',
    'inbox.archived': 'Arşivlendi',
    'inbox.hidden': 'Gizlendi',
    'inbox.updatedElsewhere': 'Başka bir cihazda güncellendi.',
    'inbox.item': '{title}, {state}',
    'prefs.title': 'Bildirim tercihleri',
    'prefs.on': 'Açık',
    'prefs.off': 'Kapalı',
    'prefs.locked': 'Açık (kilitli)',
    'prefs.lockedHint': 'Bu bildirimler hesabınız için gereklidir ve kapatılamaz.',
    'prefs.osDisabled': 'Cihaz ayarlarından kapalı',
    'prefs.cell': '{category}, {channel}: {state}',
    'prefs.stepTitle': '{category} bildirimleri nasıl gelsin?',
    'prefs.stepInstant': 'Anında al',
    'prefs.stepDigest': 'Özet al',
    'prefs.stepNever': 'Hiç alma',
    'prefs.stepCancel': 'Vazgeç',
    'prefs.lastChannel': 'Bu kategori için en az bir kanal açık kalmalı.',
    'prefs.digestNotAllowed': 'Bu kategori için özet seçilemiyor.',
    'prefs.saveFailed': 'Tercih kaydedilemedi. Lütfen tekrar deneyin.',
    'channel.push': 'Push',
    'channel.web_push': 'Web push',
    'channel.email': 'E-posta',
    'channel.sms': 'SMS',
    'channel.voice': 'Sesli arama',
    'channel.whatsapp': 'WhatsApp',
    'channel.slack': 'Slack',
    'channel.teams': 'Teams',
    'channel.telegram': 'Telegram',
    'channel.discord': 'Discord',
    'channel.in_app': 'Uygulama içi',
    'channel.webhook': 'Webhook',
  },
  en: {
    'push.fallback.title': 'New notification',
    'push.fallback.body': 'You have a new notification.',
    'inbox.title': 'Notifications',
    'inbox.bell': 'Notifications, {count} unseen',
    'inbox.bell.none': 'Notifications, none unseen',
    'inbox.empty': 'You have no notifications yet.',
    'inbox.loading': 'Loading notifications',
    'inbox.offline': 'Offline. Your changes will be sent when you reconnect.',
    'inbox.unread': 'Unread',
    'inbox.read': 'Read',
    'inbox.markRead': 'Mark as read',
    'inbox.markUnread': 'Mark as unread',
    'inbox.archive': 'Archive',
    'inbox.unarchive': 'Unarchive',
    'inbox.hide': 'Hide',
    'inbox.readAll': 'Mark all as read',
    'inbox.undo': 'Undo',
    'inbox.archived': 'Archived',
    'inbox.hidden': 'Hidden',
    'inbox.updatedElsewhere': 'Updated on another device.',
    'inbox.item': '{title}, {state}',
    'prefs.title': 'Notification preferences',
    'prefs.on': 'On',
    'prefs.off': 'Off',
    'prefs.locked': 'On (locked)',
    'prefs.lockedHint': 'These notifications are required for your account and cannot be turned off.',
    'prefs.osDisabled': 'Off in device settings',
    'prefs.cell': '{category}, {channel}: {state}',
    'prefs.stepTitle': 'How should {category} notifications reach you?',
    'prefs.stepInstant': 'Get them instantly',
    'prefs.stepDigest': 'Get a digest',
    'prefs.stepNever': 'Never',
    'prefs.stepCancel': 'Cancel',
    'prefs.lastChannel': 'At least one channel must stay on for this category.',
    'prefs.digestNotAllowed': 'A digest is not available for this category.',
    'prefs.saveFailed': 'The preference could not be saved. Please try again.',
    'channel.push': 'Push',
    'channel.web_push': 'Web push',
    'channel.email': 'Email',
    'channel.sms': 'SMS',
    'channel.voice': 'Voice call',
    'channel.whatsapp': 'WhatsApp',
    'channel.slack': 'Slack',
    'channel.teams': 'Teams',
    'channel.telegram': 'Telegram',
    'channel.discord': 'Discord',
    'channel.in_app': 'In-app',
    'channel.webhook': 'Webhook',
  },
} as const satisfies Record<RelayLocale, Record<string, string>>;

export type MessageKey = keyof (typeof MESSAGES)['en'];

/** The supported locale of a BCP 47 tag: Turkish for `tr…`, English otherwise. */
export function resolveLocale(tag: string | null | undefined): RelayLocale {
  return typeof tag === 'string' && /^tr(?:[-_]|$)/i.test(tag) ? 'tr' : 'en';
}

/** Formats a message with `{name}` placeholders. */
export function translate(
  locale: RelayLocale,
  key: MessageKey,
  values: Readonly<Record<string, string | number>> = {},
  overrides: Partial<Record<MessageKey, string>> = {},
): string {
  const template = overrides[key] ?? MESSAGES[locale][key];
  return template.replace(/\{([a-zA-Z]+)\}/g, (match, name: string) => {
    const value = values[name];
    return value === undefined ? match : String(value);
  });
}

/** The placeholders of a message, for parity checks. */
export function placeholders(template: string): string[] {
  return Array.from(template.matchAll(/\{([a-zA-Z]+)\}/g), (match) => match[1] ?? '').sort();
}
