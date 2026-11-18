import { expect, test } from "@playwright/test";
import { expectAccessible, json, mockApi, type Handler } from "./mock";

const list = (data: unknown[]) => ({
  object: "list",
  has_more: false,
  next_cursor: null,
  data,
});

const killSwitch = {
  object: "kill_switch",
  id: "ksw_01hzx3k5v7m9p2q4r6s8t0w2y4",
  scope_kind: "workflow",
  scope_ref: "spring_sale",
  channel: "sms",
  target_kind: "all",
  message_class: "marketing",
  state: "off",
  reason: "Wrong price in the template",
  origin: "operator",
  created_by: "opr_01hzx3k5v7m9p2q4r6s8t0w2y4",
  status: "active",
  created_at: "2026-11-17T09:00:00Z",
  expires_at: "2026-11-17T10:00:00Z",
};

const agent = {
  object: "agent",
  id: "agt_01hzx3k5v7m9p2q4r6s8t0w2y4",
  name: "Billing assistant",
  owner_ref: "team-billing",
  access: { party: null },
  endpoints: {
    webhook_endpoint_id: null,
    a2a_push_endpoint_id: null,
    realtime: true,
  },
  mailbox: { id: "mbx_01hzx3k5v7m9p2q4r6s8t0w2y4", state: "active" },
  topics: [],
  state: "active",
  version: 1,
  created_at: "2026-11-01T09:00:00Z",
  updated_at: "2026-11-01T09:00:00Z",
};

const day = {
  day: "2026-11-17",
  is_test: false,
  accepted: 100,
  enqueued: 100,
  dispatched: 90,
  provider_accepted: 88,
  delivered: 0,
  engaged: 5,
  sdk_receipts: 40,
  skipped: 10,
  failed: 2,
  uncertain: 0,
  expired: 0,
  cancelled: 0,
  duplicate_delivered: 0,
  conflicts: 0,
  human_clicks: 3,
  bot_clicks: 7,
  opens: 0,
  machine_opens: 0,
  recomputed_at: "2026-11-18T00:00:00Z",
};

function handlers(extra: Handler[] = []): Handler[] {
  const fixed: Record<string, unknown> = {
    "/v1/kill_switches": list([killSwitch]),
    "/v1/reports/deliveries": {
      object: "delivery_report",
      from: "2026-10-20",
      to: "2026-11-18",
      rows: [
        { ...day, channel: "push", provider: "fcm" },
        {
          ...day,
          channel: "email",
          provider: "ses",
          opens: 12,
          machine_opens: 9,
        },
      ],
    },
    "/v1/reports/skips": {
      object: "skip_report",
      from: "2026-10-20",
      to: "2026-11-18",
      rows: [
        {
          day: "2026-11-17",
          channel: "sms",
          is_test: false,
          reason: "consent_missing",
          rule_id: "consent.missing",
          skipped: 10,
          recomputed_at: "2026-11-18T00:00:00Z",
        },
      ],
    },
    "/v1/reports/costs": {
      object: "cost_report",
      from: "2026-10-20",
      to: "2026-11-18",
      rows: [],
    },
    "/v1/agents": list([agent]),
    [`/v1/agents/${agent.id}/ceiling_holds`]: list([
      {
        object: "ceiling_hold",
        notification_id: "ntf_01hzx3k5v7m9p2q4r6s8t0w2y4",
        agent_id: agent.id,
        ceiling_event_id: "oev_01hzx3k5v7m9p2q4r6s8t0w2y4",
        rule_id: "agent.ceiling",
        state: "held",
        held_at: "2026-11-17T09:00:00Z",
        expires_at: null,
        decision_id: null,
        decided_at: null,
      },
    ]),
    "/v1/waitpoints": list([]),
    "/v1/topics": list([]),
    "/v1/operator/audit_log": list([
      {
        object: "audit_record",
        id: "aud_01hzx3k5v7m9p2q4r6s8t0w2y4",
        action: "pii.revealed",
        actor_kind: "operator",
        actor_ref: "opr_01hzx3k5v7m9p2q4r6s8t0w2y4",
        on_behalf_of: "opr_01hzx3k5v7m9p2q4r6s8t0w2y4",
        target_type: "subscriber",
        target_id: "sub_01hzx3k5v7m9p2q4r6s8t0w2y4",
        reason: "Ticket 4711",
        created_at: "2026-11-17T09:00:00Z",
      },
    ]),
  };
  return [
    ...extra,
    async (route, url) => {
      if (route.request().method() !== "GET") return false;
      const body = fixed[url.pathname];
      if (body === undefined) return false;
      await json(route, 200, body);
      return true;
    },
  ];
}

test.describe("TN-41 kill switches", () => {
  test("TN-44 active kill switches are visible on every page with scope, target, class and state", async ({
    page,
  }) => {
    await mockApi(page, { handlers: handlers() });
    for (const path of [
      "/console/activity",
      "/console/workflows",
      "/console/audit",
    ]) {
      await page.goto(path);
      const bar = page.getByRole("complementary", { name: "Kill switches" });
      await expect(bar.getByText("Stopped")).toBeVisible();
      await expect(bar).toContainText(
        "workflow spring_sale × sms · all × marketing",
      );
    }
    await expectAccessible(page);
  });

  test("X-3 releasing a kill switch goes through the Access step-up", async ({
    page,
  }) => {
    let stepUp = false;
    await mockApi(page, {
      handlers: handlers([
        async (route, url) => {
          if (url.pathname.endsWith("/release")) {
            await json(route, 401, {
              type: "https://relay.example/v1/errors/auth_step_up_required",
              title: "Step-up required",
              status: 401,
              code: "auth_step_up_required",
              retryable: false,
            });
            return true;
          }
          if (url.pathname === "/v1/operator/session/step_up") {
            stepUp = true;
            await json(route, 200, {
              object: "step_up_challenge",
              authorization_url:
                "http://localhost:4173/console/activity?stepped=1",
              expires_at: "2026-11-18T10:10:00Z",
            });
            return true;
          }
          return false;
        },
      ]),
    });
    await page.goto("/console/kill-switches");
    await expectAccessible(page);
    await page.getByRole("button", { name: "Release" }).click();
    await page.getByLabel("Reason").last().fill("Price fixed");
    await page.getByRole("button", { name: "Release" }).click();
    await expect(page).toHaveURL(/stepped=1/);
    expect(stepUp).toBe(true);
  });
});

test.describe("X-6 reports", () => {
  test("push shows acceptance and SDK receipts apart, clicks split human from bot, opens carry the notice", async ({
    page,
  }) => {
    await mockApi(page, { handlers: handlers() });
    await page.goto("/console/reports");
    await expect(
      page.getByText(/Push: accepted by the push service/),
    ).toBeVisible();
    await expect(page.getByText("Human: 6").first()).toBeVisible();
    await expect(page.getByText("Likely bot: 14").first()).toBeVisible();
    await expect(page.getByText(/Open tracking is unreliable/)).toBeVisible();
    await expect(page.getByText("consent.missing")).toBeVisible();
    await expectAccessible(page);
  });
});

test.describe("AG-54 agent ceiling", () => {
  test("an operator sends all held notifications of an agent with a decision reference", async ({
    page,
  }) => {
    let body: unknown = null;
    await mockApi(page, {
      handlers: handlers([
        async (route, url) => {
          if (!url.pathname.endsWith("/ceiling_decisions")) return false;
          body = route.request().postDataJSON();
          await json(route, 201, {
            object: "ceiling_decision",
            id: "acd_01hzx3k5v7m9p2q4r6s8t0w2y4",
            agent_id: agent.id,
            ceiling_event_id: "oev_01hzx3k5v7m9p2q4r6s8t0w2y4",
            decision: "send_all",
            decision_ref: "CHG-1",
            applied_count: 1,
            agent_state: "running",
            decided_at: "2026-11-18T10:00:00Z",
          });
          return true;
        },
      ]),
    });
    await page.goto("/console/agent-ceiling");
    await page.getByRole("button", { name: "Show held notifications" }).click();
    await page.getByLabel("Decision reference").fill("CHG-1");
    await expectAccessible(page);
    await page.getByRole("button", { name: "Send all" }).click();
    await expect(page.getByText(/Applied to 1 notifications/)).toBeVisible();
    expect(body).toEqual({
      decision: "send_all",
      ceiling_event_id: "oev_01hzx3k5v7m9p2q4r6s8t0w2y4",
      decision_ref: "CHG-1",
    });
  });

  test("the audit log, waiting requests, agents and topics screens load", async ({
    page,
  }) => {
    await mockApi(page, { handlers: handlers() });
    await page.goto("/console/audit");
    await expect(page.getByText("pii.revealed")).toBeVisible();
    for (const path of [
      "/console/waitpoints",
      "/console/agents",
      "/console/topics",
    ]) {
      await page.goto(path);
      await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
      await expectAccessible(page);
    }
  });
});
