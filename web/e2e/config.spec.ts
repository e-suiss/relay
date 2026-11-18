import { expect, test } from "@playwright/test";
import { expectAccessible, json, mockApi, session, type Handler } from "./mock";

const list = (data: unknown[]) => ({
  object: "list",
  has_more: false,
  next_cursor: null,
  data,
});

const account = {
  object: "provider_account",
  id: "pva_01hzx3k5v7m9p2q4r6s8t0w2y4",
  channel: "email",
  provider: "ses",
  ownership: "tenant",
  role: "primary",
  priority: 1,
  weight: 100,
  state: "active",
  traffic: "standard",
  verification_state: "verified",
  verified_at: "2026-11-01T09:00:00Z",
  verification_rule_id: null,
  health: "healthy",
  health_checked_at: "2026-11-18T09:00:00Z",
  in_installation: false,
  processing_countries: ["US"],
  transfer_basis: "scc",
  scc_notified_on: null,
  settings: {},
  credential: null,
  version: 1,
  created_at: "2026-11-01T09:00:00Z",
  updated_at: "2026-11-01T09:00:00Z",
};

const fixed: Record<string, unknown> = {
  "/v1/provider_accounts": list([account]),
  [`/v1/provider_accounts/${account.id}/status`]: {
    object: "provider_account_status",
    provider_account_id: account.id,
    channel: "email",
    provider: "ses",
    data_residency: {
      sends_data_abroad: true,
      reference_region: "tr",
      abroad_countries: ["US"],
      in_installation: false,
      transfer_basis: "scc",
    },
    adapter: {
      declared: true,
      adapter_version: "1.2.0",
      activated: true,
      deprecation_warning: true,
      deprecations: [{ api: "SendRawEmail v1", sunset_on: "2027-03-01" }],
    },
    circuit_breaker: {
      provider: "closed",
      account: "open",
      observed_by: "node",
    },
  },
  [`/v1/provider_accounts/${account.id}/email_domains`]: {
    object: "list",
    data: [
      {
        object: "email_domain_check",
        stream: "transactional",
        domain: "mail.example.com",
        verified: false,
        checked_at: "2026-11-18T09:00:00Z",
        records: [
          {
            purpose: "dkim",
            type: "CNAME",
            name: "relay._domainkey.mail.example.com",
            value: "relay.dkim.example.net",
          },
        ],
        findings: [
          {
            severity: "error",
            code: "dkim_missing",
            subject: "mail.example.com",
          },
        ],
        spf: { record: null, lookups: 0, void_lookups: 0 },
        dmarc: null,
      },
    ],
  },
  "/v1/email_warmup_plans": list([]),
  "/v1/sender_identities": list([]),
  "/v1/channel_identities": list([]),
  "/v1/channel_costs": {
    object: "channel_cost_quote",
    channel: "sms",
    country: "TR",
    category: null,
    quantity: 1,
    data: [
      {
        provider_account_id: "pva_01hzx3k5v7m9p2q4r6s8t0w2y5",
        provider: "netgsm",
        routable: true,
        paid: true,
        priced: true,
        source: "provider_declaration",
        currency: "TRY",
        unit: "segment",
        unit_price_micros: 250000,
        total_micros: 250000,
        tier_from: null,
      },
    ],
  },
  "/v1/webhook_endpoints": list([]),
  "/v1/webhook_messages": list([
    {
      object: "webhook_message",
      id: "whm_01hzx3k5v7m9p2q4r6s8t0w2y4",
      endpoint_id: "whe_01hzx3k5v7m9p2q4r6s8t0w2y4",
      endpoint_version: 1,
      event_id: "evt_01hzx3k5v7m9p2q4r6s8t0w2y4",
      event_type: "notification.delivered",
      origin: "event",
      state: "dead_lettered",
      hold_reason: null,
      reason: "http_5xx",
      attempt_count: 12,
      next_attempt_at: null,
      last_attempt_at: "2026-11-17T09:00:00Z",
      last_response_status: 503,
      delivered_at: null,
      expires_at: null,
      created_at: "2026-11-16T09:00:00Z",
      updated_at: "2026-11-17T09:00:00Z",
    },
  ]),
  "/v1/iys/config": {
    object: "iys_config",
    mode: "own",
    api: "sandbox",
    iys_code: "123456",
    integrator_code: null,
    username: "relay",
    brands: [],
    quota: {
      state: "ok",
      consent_limit: 1000,
      used_consent_limit: 10,
      checked_at: null,
    },
    blocked_code: null,
    blocked_at: null,
    version: 1,
    created_at: "2026-11-01T09:00:00Z",
    updated_at: "2026-11-01T09:00:00Z",
  },
  "/v1/iys/uploads": list([]),
  "/v1/compliance_settings": {
    object: "compliance_settings",
    version: 1,
    refusals: [{ country: "DE", consent_kinds: ["soft_opt_in"] }],
    installation_refusals: [],
  },
  "/v1/categories": list([
    {
      object: "category",
      id: "ctg_01hzx3k5v7m9p2q4r6s8t0w2y4",
      key: "security",
      name: "Security",
      message_class: "security",
      locked: true,
      enabled: true,
      channel_defaults: {},
      default_expires_in: null,
      frequency: null,
      digest_allowed: false,
      default_route: null,
      density: null,
      state: "active",
      builtin: true,
      version: 1,
      created_at: "2026-11-01T09:00:00Z",
      updated_at: "2026-11-01T09:00:00Z",
      archived_at: null,
    },
  ]),
  "/v1/operator/api_clients": list([]),
  "/v1/operator/roles": list([
    {
      object: "role",
      key: "tenant_admin",
      scope: "tenant",
      rank: 2,
      description: "Administers one tenant and environment.",
    },
  ]),
  "/v1/operator/role_assignments": list([]),
  "/v1/operator/tenants": list([
    {
      object: "tenant_overview",
      id: "ten_01hzx3k5v7m9p2q4r6s8t0w2y4",
      access_tenant_id: "acme",
      region: "tr",
      status: "active",
      counters: {
        notifications_24h: 1200,
        queued_deliveries: 4,
        paused_deliveries: 0,
        active_kill_switches: 1,
      },
      created_at: "2026-11-01T09:00:00Z",
    },
  ]),
  "/v1/operator/region_health": {
    object: "region_health",
    region: "tr",
    status: "degraded",
    checked_at: "2026-11-18T09:00:00Z",
    checks: [
      { name: "database", status: "ok", reason: null },
      { name: "valkey", status: "unavailable", reason: "timeout" },
    ],
    queue_panel_url: "/v1/operator/queues",
  },
  "/v1/operator/kill_switches": list([]),
};

const handler: Handler = async (route, url) => {
  if (route.request().method() !== "GET") return false;
  const body = fixed[url.pathname];
  if (body === undefined) return false;
  await json(route, 200, body);
  return true;
};

test.describe("CH-36 channels and senders", () => {
  test("a provider account shows the abroad warning, the adapter deprecation and its circuit breakers", async ({
    page,
  }) => {
    await mockApi(page, { handlers: [handler] });
    await page.goto("/console/channels");
    await expect(page.getByText("Sends data abroad")).toBeVisible();
    await page.getByRole("button", { name: "Show status" }).click();
    await expect(
      page.getByText("This provider sends data abroad: US."),
    ).toBeVisible();
    await expect(
      page.getByText(/SendRawEmail v1 \(2027-03-01\)/),
    ).toBeVisible();
    await expect(page.getByText("Open (not sending)")).toBeVisible();
    await page.getByRole("button", { name: "Show cost" }).click();
    await expect(page.getByText("0.2500 TRY / segment")).toBeVisible();
    await expectAccessible(page);
  });

  test("the domain wizard lists the DNS records and findings", async ({
    page,
  }) => {
    await mockApi(page, { handlers: [handler] });
    await page.goto("/console/senders");
    await page.getByRole("button", { name: "Check DNS records" }).click();
    await expect(
      page.getByText("relay._domainkey.mail.example.com"),
    ).toBeVisible();
    await expect(page.getByText("dkim_missing")).toBeVisible();
    await expectAccessible(page);
  });
});

test.describe("WH-39 webhooks, compliance and settings", () => {
  test("a dead-lettered message can be sent again", async ({ page }) => {
    let resent = false;
    await mockApi(page, {
      handlers: [
        async (route, url) => {
          if (!url.pathname.endsWith("/resend")) return false;
          resent = true;
          await json(route, 200, {});
          return true;
        },
        handler,
      ],
    });
    await page.goto("/console/webhooks");
    await expect(page.getByRole("cell", { name: "503" })).toBeVisible();
    await expectAccessible(page);
    await page.getByRole("button", { name: "Resend" }).click();
    await expect(page.getByText("Queued again.")).toBeVisible();
    expect(resent).toBe(true);
  });

  test("compliance shows locked categories and country rules; settings show roles", async ({
    page,
  }) => {
    await mockApi(page, { handlers: [handler] });
    await page.goto("/console/compliance");
    await expect(
      page.getByText("Locked: recipients cannot turn it off"),
    ).toBeVisible();
    await expect(page.getByRole("cell", { name: "DE" })).toBeVisible();
    await expectAccessible(page);
    await page.goto("/console/settings");
    await expect(
      page.getByText("Administers one tenant and environment."),
    ).toBeVisible();
    await expectAccessible(page);
  });
});

test.describe("X-7 operator screens", () => {
  test("an installation operator sees tenants and region health; tenant roles do not see them", async ({
    page,
  }) => {
    await mockApi(page, {
      handlers: [handler],
      roles: [
        ...session.roles,
        { role: "installation_operator", tenant_id: null, environment: null },
      ],
    });
    await page.goto("/console/operator/tenants");
    await expect(
      page.getByText("ten_01hzx3k5v7m9p2q4r6s8t0w2y4").last(),
    ).toBeVisible();
    await expectAccessible(page);
    await page.goto("/console/operator/regions");
    await expect(page.getByText("Unavailable")).toBeVisible();
    await expect(
      page.getByRole("link", { name: "Open the job queue panel" }),
    ).toHaveAttribute("href", "/v1/operator/queues");
    await expectAccessible(page);
  });

  test("tenant roles have no installation section", async ({ page }) => {
    await mockApi(page, { handlers: [handler] });
    await page.goto("/console/activity");
    await expect(
      page
        .getByRole("navigation", { name: "Console sections" })
        .getByText("Tenants"),
    ).toHaveCount(0);
  });
});
