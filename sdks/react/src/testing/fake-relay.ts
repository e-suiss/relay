import type {
  FetchLike,
  InboxItem,
  InboxWaitpoint,
  SubscriberComponents,
} from "@esuiss/relay/browser";

/** A consent record as `listMyConsents` returns it. */
export type FakeConsent = SubscriberComponents["schemas"]["Consent"];

/** One request the fake received. */
export interface FakeRequest {
  readonly method: string;
  readonly path: string;
  readonly query: URLSearchParams;
  readonly body: Record<string, unknown> | null;
  readonly authorization: string | null;
}

/** The mutable state of the fake. */
export interface FakeRelayState {
  items: InboxItem[];
  countersVersion: number;
  preferences: Record<string, unknown>;
  endpoints: Record<string, unknown>[];
  eventTypes: Record<string, unknown>[];
  messages: Record<string, unknown>[];
  attempts: Record<string, Record<string, unknown>[]>;
  consents: FakeConsent[] | null;
}

/** Options of {@link createFakeRelay}. */
export interface FakeRelayOptions {
  readonly items?: readonly InboxItem[];
  readonly preferences?: Record<string, unknown>;
  readonly endpoints?: readonly Record<string, unknown>[];
  readonly eventTypes?: readonly Record<string, unknown>[];
  readonly messages?: readonly Record<string, unknown>[];
  /** The consents `listMyConsents` answers; without them the operation fails, as a Relay without the consent copy would. */
  readonly consents?: readonly FakeConsent[];
  /** A fixed clock for the fake's timestamps. */
  readonly now?: () => number;
}

/** An in-memory Relay for demos and tests of the components. */
export interface FakeRelay {
  readonly fetch: FetchLike;
  /** Returns an unsigned token shaped like a subscriber token; the fake accepts nothing else on the subscriber operations. */
  readonly token: () => string;
  /** Returns an unsigned token shaped like a portal token. */
  readonly portalToken: () => string;
  readonly state: FakeRelayState;
  readonly requests: FakeRequest[];
}

function base64url(value: string): string {
  return btoa(value).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** An unsigned JWT with the given header type, for the fake only. */
export function fakeToken(typ: string, claims: Record<string, unknown> = {}): string {
  return `${base64url(JSON.stringify({ alg: "none", typ }))}.${base64url(JSON.stringify({ exp: 4102444800, ...claims }))}.fake`;
}

/** A complete inbox item with defaults for the fields a test does not care about. */
export function fakeItem(
  id: string,
  fields: Partial<InboxItem> & Record<string, unknown> = {},
): InboxItem {
  return {
    object: "inbox_item",
    kind: "personal",
    id,
    state_version: 1,
    seen: false,
    read: false,
    archived: false,
    hidden: false,
    expired: false,
    snoozed_until: null,
    seen_at: null,
    read_at: null,
    archived_at: null,
    created_at: "2026-11-01T09:00:00Z",
    last_activity_at: "2026-11-01T09:00:00Z",
    category: null,
    tags: [],
    severity: null,
    group_key: null,
    title: `Item ${id}`,
    body: null,
    avatar_url: null,
    url: null,
    actions: [],
    data: [],
    locale: null,
    dir: null,
    activity_count: 1,
    actor_count: 0,
    expires_at: null,
    sender_type: null,
    approval: false,
    waitpoint: null,
    ...fields,
  };
}

/** A complete waitpoint of an inbox item with defaults for the fields a test does not care about. */
export function fakeWaitpoint(id: string, fields: Partial<InboxWaitpoint> = {}): InboxWaitpoint {
  return {
    id,
    kind: "response",
    status: "awaiting",
    subject_digest: null,
    options: [],
    responder: null,
    responded_at: null,
    approval_url: null,
    ...fields,
  };
}

/** A complete consent record with defaults for the fields a test does not care about. */
export function fakeConsent(
  channel: FakeConsent["channel"],
  status: FakeConsent["status"],
  fields: Partial<FakeConsent> = {},
): FakeConsent {
  return {
    object: "consent",
    id: `cns_${channel}`,
    brand: null,
    channel,
    status,
    consent_kind: null,
    recipient_type: null,
    source: "access",
    occurred_at: "2026-11-01T09:00:00Z",
    ...fields,
  };
}

function str(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function json(status: number, body: unknown): Response {
  return new Response(body === null ? null : JSON.stringify(body), {
    status,
    headers: {
      "content-type": status >= 400 ? "application/problem+json" : "application/json",
      "request-id": "req_fake",
    },
  });
}

function problem(status: number, code: string, detail: string, errors: unknown[] = []): Response {
  return json(status, {
    type: `https://relay.example.com/v1/errors/${code}`,
    title: detail,
    status,
    code,
    retryable: false,
    detail,
    errors,
  });
}

function blockedHost(url: string): boolean {
  try {
    const host = new URL(url).hostname;
    return (
      host === "localhost" ||
      /^(127|10)\./.test(host) ||
      /^192\.168\./.test(host) ||
      host.endsWith(".internal")
    );
  } catch {
    return true;
  }
}

/**
 * Creates an in-memory Relay that answers the subscriber and portal operations the components use, for demos, tests and Storybook. It never talks to the network.
 */
export function createFakeRelay(options: FakeRelayOptions = {}): FakeRelay {
  const now = options.now ?? Date.now;
  const state: FakeRelayState = {
    items: [...(options.items ?? [])],
    countersVersion: 1,
    preferences: options.preferences ?? {
      object: "subscriber_preferences",
      subscriber_id: "sub_fake",
      cells: [],
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
    },
    endpoints: [...(options.endpoints ?? [])],
    eventTypes: [...(options.eventTypes ?? [])],
    messages: [...(options.messages ?? [])],
    attempts: {},
    consents: options.consents === undefined ? null : [...options.consents],
  };
  const requests: FakeRequest[] = [];
  let sequence = 0;
  const id = (prefix: string) => `${prefix}_${String(++sequence).padStart(26, "0")}`;
  const iso = () => new Date(now()).toISOString();

  const visible = (item: InboxItem) =>
    !item.archived &&
    !item.hidden &&
    !item.expired &&
    (item.snoozed_until === null || Date.parse(item.snoozed_until) <= now());
  const counters = () => {
    const shown = state.items.filter(visible);
    return {
      object: "inbox_counters",
      unseen: shown.filter((item) => !item.seen).length,
      unread: shown.filter((item) => !item.read).length,
      total: shown.length,
      version: state.countersVersion,
    };
  };
  const bump = () => {
    state.countersVersion += 1;
  };
  const stateOf = (item: InboxItem) => ({
    id: item.id,
    state_version: item.state_version,
    seen: item.seen,
    read: item.read,
    archived: item.archived,
    hidden: item.hidden,
    expired: item.expired,
    snoozed_until: item.snoozed_until,
    seen_at: item.seen_at ?? null,
    read_at: item.read_at ?? null,
    archived_at: item.archived_at ?? null,
  });
  const update = (itemId: string, change: Partial<InboxItem>) => {
    state.items = state.items.map((item) =>
      item.id === itemId ? { ...item, ...change, state_version: item.state_version + 1 } : item,
    );
  };

  const route = (request: FakeRequest): Response => {
    const { method, path, body, query } = request;
    const segments = path.split("/").filter((part) => part.length > 0);
    const subscriber = path.startsWith("/v1/subscriber");
    const portal = path.startsWith("/v1/portal");
    const auth = request.authorization ?? "";
    const typ = (() => {
      try {
        const header = auth.replace(/^Bearer /, "").split(".")[0] ?? "";
        return (JSON.parse(atob(header.replace(/-/g, "+").replace(/_/g, "/"))) as { typ?: string })
          .typ;
      } catch {
        return undefined;
      }
    })();
    if (subscriber && typ !== "relay-subscriber+jwt")
      return problem(401, "auth_invalid_token", "A subscriber token is required.");
    if (portal && typ !== "relay-webhook-portal+jwt")
      return problem(401, "auth_invalid_token", "A portal token is required.");

    if (path === "/v1/subscriber/inbox/counters" && method === "GET") return json(200, counters());
    if (path === "/v1/subscriber/inbox/items" && method === "GET") {
      const status = query.get("status") ?? "inbox";
      const items = state.items.filter((item) =>
        status === "archived" ? item.archived && !item.hidden : visible(item),
      );
      return json(200, {
        object: "list",
        data: items,
        has_more: false,
        next_cursor: null,
        previous_cursor: null,
        counters: counters(),
        cursor: `c${state.countersVersion}`,
      });
    }
    if (segments[3] === "items" && segments.length === 5 && method === "GET") {
      const item = state.items.find((entry) => entry.id === segments[4]);
      return item === undefined
        ? problem(404, "inbox_item_not_found", "No such item.")
        : json(200, item);
    }
    if (segments[3] === "items" && segments[5] === "intents" && method === "POST") {
      const itemId = segments[4] ?? "";
      const op = String(body?.op);
      const changes: Record<string, Partial<InboxItem>> = {
        seen: { seen: true, seen_at: iso() },
        read: { read: true, seen: true, read_at: iso() },
        unread: { read: false },
        archive: { archived: true, archived_at: iso() },
        unarchive: { archived: false },
        hide: { hidden: true },
        snooze: { snoozed_until: str(body?.snooze_until) },
        unsnooze: { snoozed_until: null },
        click: {},
      };
      if (op !== "click") {
        update(itemId, changes[op] ?? {});
        bump();
      }
      const item = state.items.find((entry) => entry.id === itemId);
      if (item === undefined) return problem(404, "inbox_item_not_found", "No such item.");
      return json(200, {
        object: "inbox_intent_result",
        item_id: itemId,
        op,
        client_seq: body?.client_seq ?? null,
        result: "applied",
        state: stateOf(item),
        counters: counters(),
      });
    }
    if (path === "/v1/subscriber/inbox/read_all" && method === "POST") {
      const category = str(body?.category);
      let updated = 0;
      for (const item of state.items) {
        if (visible(item) && !item.read && (category === null || item.category === category)) {
          update(item.id, { read: true, seen: true, read_at: iso() });
          updated += 1;
        }
      }
      bump();
      return json(200, {
        object: "inbox_read_all_result",
        scope: category === null ? "all" : "category",
        category,
        updated,
        cut_off: iso(),
        counters: counters(),
      });
    }
    if (path === "/v1/subscriber/inbox/bulk" && method === "POST") {
      const filter = (body?.filter ?? {}) as { tag?: string; category?: string };
      let updated = 0;
      for (const item of state.items) {
        const tags = Array.isArray(item.tags) ? (item.tags as string[]) : [];
        if (
          visible(item) &&
          !item.read &&
          (filter.tag === undefined || tags.includes(filter.tag)) &&
          (filter.category === undefined || item.category === filter.category)
        ) {
          update(item.id, { read: true, seen: true });
          updated += 1;
        }
      }
      bump();
      return json(202, {
        object: "inbox_bulk_operation",
        id: id("ibk"),
        action: "read",
        state: "completed",
        matched: updated,
        updated,
      });
    }
    if (path === "/v1/subscriber/inbox/changes" && method === "GET") {
      return json(200, {
        object: "inbox_changes",
        changes: state.items.map((item) => ({
          type: "created",
          item_id: item.id,
          state_version: item.state_version,
          cursor: "c",
          item,
        })),
        cursor: `c${state.countersVersion}`,
        has_more: false,
        truncated: false,
        resync_required: false,
        counters: counters(),
      });
    }
    if (path === "/v1/subscriber/inbox/counters/inconsistency" && method === "POST") {
      return json(200, {
        object: "inbox_reconciliation",
        result: "consistent",
        counters: counters(),
      });
    }
    if (segments[2] === "waitpoints" && segments[4] === "response" && method === "POST") {
      return json(200, {
        object: "waitpoint_response_receipt",
        waitpoint_id: segments[3],
        status: "responded",
        responder: { recipient_id: "sub_fake", kind: "subscriber" },
        responded_at: iso(),
      });
    }
    if (path === "/v1/subscriber/consents" && method === "GET") {
      if (state.consents === null)
        return problem(404, "not_found", "The fake has no consent copy.");
      return json(200, {
        object: "list",
        data: state.consents,
        has_more: false,
        next_cursor: null,
        previous_cursor: null,
      });
    }
    if (path === "/v1/subscriber/preferences" && method === "GET")
      return json(200, state.preferences);
    if (path === "/v1/subscriber/preferences" && method === "PATCH") {
      const prefs = state.preferences as {
        cells: Record<string, unknown>[];
        channels: Record<string, unknown>[];
        workflows: Record<string, unknown>[];
        scope_keys: Record<string, unknown>[];
        profile: Record<string, unknown>;
      };
      for (const write of (body?.preferences ?? []) as Record<string, string>[]) {
        if (write.level === "category_channel") {
          const cell = prefs.cells.find(
            (entry) => entry.category === write.category && entry.channel === write.channel,
          );
          if (cell?.locked === true && write.value === "opt_out")
            return problem(
              422,
              "preference_last_channel",
              "The last open channel of a locked category cannot be closed.",
            );
          prefs.cells = prefs.cells.map((entry) =>
            entry.category === write.category && entry.channel === write.channel
              ? {
                  ...entry,
                  value: write.value,
                  effective: write.value !== "opt_out",
                  source: "user",
                }
              : entry,
          );
        } else {
          const listKey =
            write.level === "channel"
              ? "channels"
              : write.level === "workflow"
                ? "workflows"
                : "scope_keys";
          const nameKey =
            write.level === "channel"
              ? "channel"
              : write.level === "workflow"
                ? "workflow"
                : "scope_key";
          const list = prefs[listKey];
          const name = write[nameKey];
          prefs[listKey] = list.some((entry) => entry[nameKey] === name)
            ? list.map((entry) =>
                entry[nameKey] === name ? { ...entry, value: write.value } : entry,
              )
            : [...list, { [nameKey]: name, value: write.value }];
        }
      }
      const profile = body?.profile;
      if (typeof profile === "object" && profile !== null)
        prefs.profile = { ...prefs.profile, ...(profile as Record<string, unknown>) };
      return json(200, state.preferences);
    }

    const list = (data: unknown[]) =>
      json(200, { object: "list", data, has_more: false, next_cursor: null });
    if (path === "/v1/portal/webhook_event_types" && method === "GET")
      return list(state.eventTypes);
    if (path === "/v1/portal/webhook_endpoints" && method === "GET")
      return list(state.endpoints.filter((endpoint) => endpoint.state !== "archived"));
    if (path === "/v1/portal/webhook_endpoints" && method === "POST") {
      const url = String(body?.url ?? "");
      if (blockedHost(url)) {
        return problem(422, "webhook_endpoint_url_not_allowed", "Endpoint address is not allowed", [
          {
            pointer: "/url",
            code: "address_blocked",
            detail: "the host resolves to a private address",
          },
        ]);
      }
      const endpoint = {
        object: "webhook_endpoint",
        id: id("whe"),
        destination: { kind: "https", url, auth: "none" },
        event_types: body?.event_types ?? [],
        description: body?.description ?? null,
        state: "active",
        disabled_reason: null,
        signature_scheme: "v1a",
        signing_keys: [
          {
            id: id("whk"),
            scheme: "v1a",
            state: "active",
            public_key: "whpk_fake",
            activated_at: iso(),
            expires_at: null,
          },
        ],
        managed_by: "tenant",
      };
      state.endpoints = [endpoint, ...state.endpoints];
      return json(201, { ...endpoint, secret: null, previous_key_expires_at: null });
    }
    if (segments[2] === "webhook_endpoints" && segments.length >= 4) {
      const endpointId = segments[3];
      const endpoint = state.endpoints.find((entry) => entry.id === endpointId);
      if (endpoint === undefined)
        return problem(404, "webhook_endpoint_not_found", "No such endpoint.");
      const action = segments[4];
      const replace = (next: Record<string, unknown>) => {
        state.endpoints = state.endpoints.map((entry) => (entry.id === endpointId ? next : entry));
        return next;
      };
      if (action === undefined && method === "GET") return json(200, endpoint);
      if (action === undefined && method === "PATCH") {
        const newUrl = str(body?.url);
        if (newUrl !== null && blockedHost(newUrl)) {
          return problem(
            422,
            "webhook_endpoint_url_not_allowed",
            "Endpoint address is not allowed",
            [
              {
                pointer: "/url",
                code: "address_blocked",
                detail: "the host resolves to a private address",
              },
            ],
          );
        }
        const next = { ...endpoint, ...(body ?? {}) } as Record<string, unknown>;
        if (newUrl !== null) next.destination = { kind: "https", url: newUrl, auth: "none" };
        delete next.url;
        if (body?.state === "disabled") next.disabled_reason = "manual";
        if (body?.state === "active") next.disabled_reason = null;
        return json(200, replace(next));
      }
      if (action === "archive") return json(200, replace({ ...endpoint, state: "archived" }));
      if (action === "rotate_key")
        return json(200, {
          ...endpoint,
          secret: null,
          previous_key_expires_at: new Date(now() + 86_400_000).toISOString(),
        });
      if (action === "health") {
        return json(200, {
          object: "webhook_endpoint_health",
          endpoint_id: endpointId,
          state: endpoint.state,
          disabled_reason: endpoint.disabled_reason ?? null,
          window: "PT24H",
          succeeded: 98,
          failed: 2,
          success_rate_bp: 9800,
          latency_ms: { p50: 120, p95: 340, p99: 800 },
          last_success_at: iso(),
          last_failure_at: iso(),
          failing_since: null,
          disable_at: null,
          backlog: { waiting: 0, held: 0, oldest_at: null },
          breaker: { state: "closed", opened_at: null, retry_at: null },
          recent_failures: [{ code: "http_5xx", count: 2, last_at: iso() }],
        });
      }
      if (action === "test")
        return json(201, {
          object: "webhook_message",
          id: id("whm"),
          endpoint_id: endpointId,
          event_type: "webhook_endpoint.tested",
          state: "pending",
          attempt_count: 0,
          next_attempt_at: null,
          created_at: iso(),
        });
      if (action === "recover")
        return json(200, {
          object: "webhook_recovery",
          operation: "recover",
          endpoint_id: endpointId,
          selected: state.messages.filter(
            (message) => message.endpoint_id === endpointId && message.state !== "delivered",
          ).length,
        });
    }
    if (path === "/v1/portal/webhook_messages" && method === "GET") {
      const filtered = state.messages.filter(
        (message) =>
          (query.get("endpoint_id") === null || message.endpoint_id === query.get("endpoint_id")) &&
          (query.get("state") === null || message.state === query.get("state")) &&
          (query.get("event_type") === null || message.event_type === query.get("event_type")),
      );
      return list(filtered);
    }
    if (segments[2] === "webhook_messages" && segments[4] === "attempts" && method === "GET")
      return list(state.attempts[segments[3] ?? ""] ?? []);
    if (segments[2] === "webhook_messages" && segments[4] === "resend" && method === "POST") {
      const message = state.messages.find((entry) => entry.id === segments[3]);
      if (message === undefined)
        return problem(404, "webhook_message_not_found", "No such message.");
      return json(200, { ...message, state: "in_flight" });
    }
    return problem(404, "not_found", `The fake does not answer ${method} ${path}.`);
  };

  const fetch: FetchLike = async (input, init) => {
    const url = new URL(input);
    const headers = new Headers(init?.headers);
    const request: FakeRequest = {
      method: init?.method ?? "GET",
      path: url.pathname,
      query: url.searchParams,
      body:
        typeof init?.body === "string" && init.body.length > 0
          ? (JSON.parse(init.body) as Record<string, unknown>)
          : null,
      authorization: headers.get("authorization"),
    };
    requests.push(request);
    return route(request);
  };

  return {
    fetch,
    token: () =>
      fakeToken("relay-subscriber+jwt", {
        sub: "sub_fake",
        scope: "inbox:read inbox:write preferences",
      }),
    portalToken: () => fakeToken("relay-webhook-portal+jwt", { sub: "whc_fake" }),
    state,
    requests,
  };
}
