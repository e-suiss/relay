import { json, type Handler } from "./mock";

export const subscriber = {
  object: "subscriber",
  id: "sub_01hzx3k5v7m9p2q4r6s8t0w2y4",
  external_id: "seed_no_consent",
  email: "seed_no_consent@seed.relay.test",
  phone: "+905321234567",
  name: "Seed No Consent",
  locale: "tr-TR",
  timezone: "Europe/Istanbul",
  attributes: {},
  channels: {
    email: { reachable: true, reason: null },
    sms: { reachable: true, reason: null },
    push: { reachable: false, reason: "no_active_device" },
  },
  state: "active",
  version: 3,
  created_at: "2026-11-01T09:00:00Z",
  updated_at: "2026-11-10T09:00:00Z",
};

export const sentence =
  "Not sent because the compliance table asks for consent for this message on this channel and there is no active consent.";

export const decisions = {
  object: "list",
  has_more: false,
  next_cursor: null,
  data: [
    {
      object: "notification_decision",
      notification_id: "ntf_01hzx3k5v7m9p2q4r6s8t0w2y4",
      event_id: "evt_01hzx3k5v7m9p2q4r6s8t0w2y4",
      workflow: { key: "spring_sale", version: 2 },
      message_class: "marketing",
      state: "active",
      close_rule_id: null,
      created_at: "2026-11-17T10:00:00Z",
      deliveries: [
        {
          delivery_id: "dlv_01hzx3k5v7m9p2q4r6s8t0w2y4",
          channel: "sms",
          status: "skipped",
          reason: "consent_missing",
          rule_id: "consent.missing",
          gates: "stopped",
          deferred_until: null,
          decisions: [
            {
              type: "notification.suppressed",
              rule_id: "consent.missing",
              reason: "consent_missing",
              outcome: "skip",
              detail: { channel: "sms", required_consent: "explicit_opt_in" },
              description: {
                en: sentence,
                tr: "Uyum tablosu bu kanalda bu ileti için izin istediği ve etkin izin olmadığı için gönderilmedi.",
              },
              occurred_at: "2026-11-17T10:00:01Z",
            },
          ],
        },
        {
          delivery_id: "dlv_01hzx3k5v7m9p2q4r6s8t0w2y5",
          channel: "push",
          status: "sent",
          reason: null,
          rule_id: null,
          gates: "passed",
          deferred_until: null,
          decisions: [],
        },
      ],
    },
  ],
};

const list = (data: unknown[]) => ({
  object: "list",
  has_more: false,
  next_cursor: null,
  data,
});

export const notification = {
  object: "notification",
  id: "ntf_01hzx3k5v7m9p2q4r6s8t0w2y4",
  event_id: "evt_01hzx3k5v7m9p2q4r6s8t0w2y4",
  workflow: { key: "spring_sale", version: 2 },
  recipient_id: subscriber.id,
  external_id: subscriber.external_id,
  message_class: "marketing",
  sender_type: "agent",
  dedup_key: "spring",
  state: "active",
  close_rule_id: null,
  delivery_counts: { skipped: 1, sent: 1 },
  is_test: true,
  created_at: "2026-11-17T10:00:00Z",
  updated_at: "2026-11-17T10:00:02Z",
};

export const deliveries = list([
  {
    object: "delivery",
    id: "dlv_01hzx3k5v7m9p2q4r6s8t0w2y4",
    notification_id: notification.id,
    channel: "sms",
    status: "skipped",
    reason: "consent_missing",
    rule_id: "consent.missing",
    created_at: "2026-11-17T10:00:00Z",
    updated_at: "2026-11-17T10:00:01Z",
  },
  {
    object: "delivery",
    id: "dlv_01hzx3k5v7m9p2q4r6s8t0w2y5",
    notification_id: notification.id,
    channel: "push",
    status: "sent",
    engagement: { clicked_by: "bot", clicked_at: "2026-11-17T10:05:00Z" },
    accepted_at: "2026-11-17T10:00:02Z",
    created_at: "2026-11-17T10:00:00Z",
    updated_at: "2026-11-17T10:00:02Z",
  },
]);

export const history = {
  object: "delivery_history",
  delivery: deliveries.data[1],
  attempts: [
    {
      object: "attempt",
      id: "att_01hzx3k5v7m9p2q4r6s8t0w2y4",
      attempt_no: 1,
      state: "succeeded",
      provider: "fcm",
      failure_class: null,
      raw_code: "200",
      started_at: "2026-11-17T10:00:01Z",
      finished_at: "2026-11-17T10:00:02Z",
    },
  ],
  events: [
    {
      object: "delivery_event",
      id: "dle_01hzx3k5v7m9p2q4r6s8t0w2y4",
      actor: "provider_api",
      type: "delivery.sent",
      attempt_no: 1,
      raw_code: "200",
      provider: "fcm",
      outcome: "applied",
      reason: null,
      rule_id: null,
      occurred_at: "2026-11-17T10:00:02Z",
      received_at: "2026-11-17T10:00:02Z",
    },
  ],
};

const consents = list([
  {
    object: "consent",
    id: "cns_01hzx3k5v7m9p2q4r6s8t0w2y4",
    brand: null,
    channel: "sms",
    status: "none",
    consent_kind: null,
    recipient_type: null,
    source: "seed",
    occurred_at: "2026-11-01T09:00:00Z",
  },
]);

const preferences = {
  object: "subscriber_preferences",
  subscriber_id: subscriber.id,
  cells: [
    {
      category: "marketing",
      channel: "sms",
      value: "unset",
      effective: true,
      source: "category_default",
    },
  ],
  channels: [],
  workflows: [],
  scope_keys: [],
  profile: {
    quiet_hours: [],
    schedule: [],
    dnd_until: null,
    quiet_hours_email: false,
    digest: {},
  },
};

const devices = list([]);

/** Handlers for the subscriber and activity reads of the why-didn't-I-receive and activity screens. */
export const recipientHandlers: Handler[] = [
  async (route, url) => {
    const base = `/v1/subscribers/${subscriber.external_id}`;
    const routes: Record<string, unknown> = {
      [base]: subscriber,
      [`${base}/decisions`]: decisions,
      [`${base}/consents`]: consents,
      [`${base}/preferences`]: preferences,
      [`${base}/devices`]: devices,
      [`${base}/subscriptions`]: list([]),
      [`/v1/notifications/${notification.id}`]: notification,
      [`/v1/notifications/${notification.id}/deliveries`]: deliveries,
      [`/v1/deliveries/${deliveries.data[1]?.id ?? ""}/history`]: history,
      "/v1/notifications": list([notification]),
    };
    if (url.pathname === "/v1/subscribers") {
      const phone = url.searchParams.get("phone");
      const email = url.searchParams.get("email");
      const match =
        phone === subscriber.phone || email === subscriber.email
          ? [subscriber]
          : phone === null && email === null
            ? [subscriber]
            : [];
      await json(route, 200, list(match));
      return true;
    }
    const body = routes[url.pathname];
    if (body === undefined) return false;
    await json(route, 200, body);
    return true;
  },
];
