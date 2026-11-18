import type { RelaySubscriberClient } from "@esuiss/relay/browser";

/** An endpoint of the portal token's consumer. */
export interface PortalEndpoint {
  readonly id: string;
  readonly destination: { readonly kind?: string; readonly url?: string };
  readonly event_types: readonly string[];
  readonly description: string | null;
  readonly state: "active" | "paused" | "disabled" | "archived";
  readonly disabled_reason: "manual" | "failing" | "gone" | null;
  readonly signature_scheme: string | null;
  readonly signing_keys: readonly {
    readonly id: string;
    readonly scheme: string;
    readonly state: "active" | "previous";
    readonly public_key: string | null;
    readonly expires_at: string | null;
  }[];
  readonly managed_by?: "tenant" | "product";
}

/** An endpoint answer that may carry a v1 secret shown only once (WH-5). */
export interface PortalEndpointSecret extends PortalEndpoint {
  readonly secret: string | null;
  readonly previous_key_expires_at: string | null;
}

/** A tenant event type an endpoint can subscribe to (WH-46). */
export interface PortalEventType {
  readonly id: string;
  readonly name: string;
  readonly description: string | null;
}

/** The health of an endpoint (WH-39). */
export interface PortalHealth {
  readonly state: PortalEndpoint["state"];
  readonly disabled_reason: PortalEndpoint["disabled_reason"];
  readonly succeeded: number;
  readonly failed: number;
  readonly success_rate_bp: number | null;
  readonly latency_ms: { readonly p50: number; readonly p95: number; readonly p99: number } | null;
  readonly last_success_at: string | null;
  readonly failing_since: string | null;
  readonly disable_at: string | null;
  readonly backlog: { readonly waiting: number; readonly held: number };
  readonly breaker: { readonly state: "closed" | "open" | "half_open" };
  readonly recent_failures: readonly {
    readonly code: string;
    readonly count: number;
    readonly last_at: string;
  }[];
}

/** A delivery of one event to one endpoint (WH-2). */
export interface PortalMessage {
  readonly id: string;
  readonly endpoint_id: string;
  readonly event_type: string;
  readonly state: string;
  readonly attempt_count: number;
  readonly next_attempt_at: string | null;
  readonly last_response_status: number | null;
  readonly created_at: string;
}

/** One attempt of a delivery (WH-10). */
export interface PortalAttempt {
  readonly id: string;
  readonly attempt_no: number;
  readonly result:
    "succeeded" | "failed_retryable" | "failed_permanent" | "aborted" | "deferred" | null;
  readonly failure_code: string | null;
  readonly response_status: number | null;
  readonly duration_ms: number | null;
  readonly started_at: string;
}

/** A page of a portal list. */
export interface PortalPage<T> {
  readonly data: readonly T[];
  readonly has_more: boolean;
  readonly next_cursor: string | null;
}

/** Filters of the delivery log. */
export interface MessageFilter {
  readonly endpoint_id?: string;
  readonly state?: string;
  readonly event_type?: string;
}

function page<T>(raw: unknown): PortalPage<T> {
  const record = raw as { data?: T[]; has_more?: boolean; next_cursor?: string | null };
  return {
    data: record.data ?? [],
    has_more: record.has_more ?? false,
    next_cursor: record.next_cursor ?? null,
  };
}

/**
 * The portal API family (WH-46, WH-47) over a client that holds the tenant-minted portal token: every call reads or changes only the token consumer's endpoints and messages.
 */
export class PortalApi {
  readonly #client: RelaySubscriberClient;

  constructor(client: RelaySubscriberClient) {
    this.#client = client;
  }

  /** Every active event type of the tenant's catalog. */
  async eventTypes(): Promise<PortalEventType[]> {
    const types: PortalEventType[] = [];
    let cursor: string | null = null;
    for (;;) {
      const result: PortalPage<PortalEventType> = page<PortalEventType>(
        await this.#client.call("listPortalWebhookEventTypes", {
          query: { limit: 100, ...(cursor === null ? {} : { starting_after: cursor }) },
        } as never),
      );
      types.push(...result.data);
      if (!result.has_more || result.next_cursor === null) return types;
      cursor = result.next_cursor;
    }
  }

  async endpoints(): Promise<PortalEndpoint[]> {
    return [
      ...page<PortalEndpoint>(
        await this.#client.call("listPortalWebhookEndpoints", { query: { limit: 100 } } as never),
      ).data,
    ];
  }

  async create(body: {
    url: string;
    event_types: string[];
    description?: string;
  }): Promise<PortalEndpointSecret> {
    return (await this.#client.call("createPortalWebhookEndpoint", {
      body: { ...body, signature_scheme: "v1a" },
    } as never)) as unknown as PortalEndpointSecret;
  }

  async update(
    id: string,
    body: {
      url?: string;
      event_types?: string[];
      description?: string | null;
      state?: "active" | "disabled";
    },
  ): Promise<PortalEndpoint> {
    return (await this.#client.call("updatePortalWebhookEndpoint", {
      path: { webhook_endpoint_id: id },
      body,
    } as never)) as unknown as PortalEndpoint;
  }

  async archive(id: string): Promise<PortalEndpoint> {
    return (await this.#client.call("archivePortalWebhookEndpoint", {
      path: { webhook_endpoint_id: id },
    } as never)) as unknown as PortalEndpoint;
  }

  async rotate(id: string): Promise<PortalEndpointSecret> {
    return (await this.#client.call("rotatePortalWebhookEndpointKey", {
      path: { webhook_endpoint_id: id },
      body: {},
    } as never)) as unknown as PortalEndpointSecret;
  }

  async health(id: string): Promise<PortalHealth> {
    return (await this.#client.call("getPortalWebhookEndpointHealth", {
      path: { webhook_endpoint_id: id },
    } as never)) as unknown as PortalHealth;
  }

  async test(id: string, eventType?: string): Promise<PortalMessage> {
    return (await this.#client.call("sendPortalWebhookEndpointTestEvent", {
      path: { webhook_endpoint_id: id },
      body: eventType === undefined ? {} : { event_type: eventType },
    } as never)) as unknown as PortalMessage;
  }

  async recover(id: string, since: string, until?: string): Promise<{ selected: number }> {
    return (await this.#client.call("recoverPortalWebhookEndpoint", {
      path: { webhook_endpoint_id: id },
      body: { since, ...(until === undefined ? {} : { until }) },
    } as never)) as unknown as { selected: number };
  }

  async messages(
    filter: MessageFilter,
    cursor: string | null = null,
  ): Promise<PortalPage<PortalMessage>> {
    return page<PortalMessage>(
      await this.#client.call("listPortalWebhookMessages", {
        query: { limit: 25, ...filter, ...(cursor === null ? {} : { starting_after: cursor }) },
      } as never),
    );
  }

  async attempts(messageId: string): Promise<PortalAttempt[]> {
    return [
      ...page<PortalAttempt>(
        await this.#client.call("listPortalWebhookMessageAttempts", {
          path: { webhook_message_id: messageId },
          query: { limit: 100 },
        } as never),
      ).data,
    ];
  }

  async resend(messageId: string): Promise<PortalMessage> {
    return (await this.#client.call("resendPortalWebhookMessage", {
      path: { webhook_message_id: messageId },
    } as never)) as unknown as PortalMessage;
  }
}

/** Whether an endpoint address passes the client check before it is sent: https and a host (WH-40). */
export function httpsUrl(url: string): boolean {
  try {
    const parsed = new URL(url);
    return (
      parsed.protocol === "https:" &&
      parsed.hostname.length > 0 &&
      parsed.username === "" &&
      parsed.password === ""
    );
  } catch {
    return false;
  }
}

/** Failed message states a delivery log can filter by and resend. */
export const messageStates = [
  "pending",
  "scheduled",
  "in_flight",
  "held",
  "delivered",
  "failed_permanent",
  "exhausted",
  "expired",
  "window_exceeded",
  "dead_lettered",
  "cancelled",
] as const;
