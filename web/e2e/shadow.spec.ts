import { expect, test } from "@playwright/test";
import { expectAccessible, json, mockApi, type Handler } from "./mock";

const dayMs = 24 * 60 * 60 * 1000;

const coverage = {
  object: "shadow_coverage",
  window_days: 14,
  first_observed_at: "2026-11-08T09:00:00Z",
  days_observed: 10,
  cycles_met: false,
  unexplained_decision_differences: 2,
  active_intentional_differences: 2,
  exit_criteria_met: false,
  rows: [
    {
      template: "welcome",
      locale: "tr-TR",
      channel: "email",
      observed: 340,
      decision_differences: 4,
      explained: 4,
      unexplained: 0,
      content_differences: 1,
      routing_differences: 0,
      sufficient: true,
    },
    {
      template: "password_reset",
      locale: "en-GB",
      channel: "sms",
      observed: 12,
      decision_differences: 2,
      explained: 0,
      unexplained: 2,
      content_differences: 0,
      routing_differences: 1,
      sufficient: false,
    },
  ],
};

function difference(id: string, overrides: Record<string, unknown> = {}) {
  return {
    id,
    object: "shadow_difference",
    layer: "decision",
    field: "quiet_hours",
    template: "welcome",
    channel: "email",
    owner: "team-growth",
    reason: "Relay applies quiet hours the old system ignored",
    expires_at: new Date(Date.now() + 20 * dayMs).toISOString(),
    renewals: 0,
    state: "active",
    created_at: "2026-11-08T09:00:00Z",
    updated_at: "2026-11-08T09:00:00Z",
    ...overrides,
  };
}

const differences = {
  object: "list",
  has_more: false,
  next_cursor: null,
  data: [
    difference("sdf_01hzx3k5v7m9p2q4r6s8t0w2y4"),
    difference("sdf_01hzx3k5v7m9p2q4r6s8t0w2y5", {
      layer: "content",
      field: null,
      template: null,
      channel: "sms",
      owner: "team-ops",
      reason: "Sender name differs on purpose",
      expires_at: new Date(Date.now() + dayMs).toISOString(),
      renewals: 2,
    }),
  ],
};

function handlers(extra: Handler[] = []): Handler[] {
  return [
    ...extra,
    async (route, url) => {
      if (route.request().method() !== "GET") return false;
      if (url.pathname === "/v1/shadow/coverage") {
        await json(route, 200, coverage);
        return true;
      }
      if (url.pathname === "/v1/shadow/differences") {
        await json(route, 200, differences);
        return true;
      }
      return false;
    },
  ];
}

test.describe("OP-94 shadow comparison", () => {
  test("OP-79 the coverage report shows each exit criterion and flags the rows that hold it back", async ({
    page,
  }) => {
    await mockApi(page, { handlers: handlers() });
    await page.goto("/console/activity");
    await page
      .getByRole("navigation", { name: "Console sections" })
      .getByRole("link", { name: "Shadow comparison" })
      .click();
    await expect(
      page.getByRole("heading", { level: 1, name: "Shadow comparison" }),
    ).toBeVisible();
    await expect(page.getByText("Exit criteria not met")).toBeVisible();
    await expect(page.getByRole("note")).toContainText("not delivery quality");
    await expect(page.locator('[data-criterion="combinations"]')).toContainText(
      "(1 of 2)",
    );
    await expect(page.locator('[data-criterion="days"]')).toContainText(
      "At least 14 days observed (10 so far).",
    );
    await expect(page.locator('[data-criterion="unexplained"]')).toContainText(
      "Not met",
    );
    const flagged = page.getByRole("row", { name: /password_reset/ });
    await expect(flagged.getByText("Not enough observations")).toBeVisible();
    await expect(flagged.getByText("Unexplained differences")).toBeVisible();
    const fine = page.getByRole("row", { name: /welcome.*tr-TR/ });
    await expect(fine.getByText("Enough observations")).toBeVisible();
    const firstRow = page.getByRole("table").first().getByRole("row").nth(1);
    await expect(firstRow).toContainText("welcome");
    const order = page.getByLabel("Order rows by");
    await order.selectOption({ label: "Most unexplained differences first" });
    await expect(firstRow).toContainText("password_reset");
    await expectAccessible(page);
  });

  test("OP-79 intentional differences show owner, reason, scope, renewals and an expires-soon hint", async ({
    page,
  }) => {
    await mockApi(page, { handlers: handlers() });
    await page.goto("/console/migration/shadow");
    const soon = page.getByRole("row", { name: /team-ops/ });
    await expect(soon.getByText("Expires soon")).toBeVisible();
    await expect(
      soon.getByText("Sender name differs on purpose"),
    ).toBeVisible();
    await expect(
      soon.getByRole("cell", { name: "2", exact: true }),
    ).toBeVisible();
    const later = page.getByRole("row", { name: /team-growth/ });
    await expect(
      later.getByText("welcome · email · quiet_hours"),
    ).toBeVisible();
    await expect(later.getByText("Expires soon")).toHaveCount(0);
    await expectAccessible(page);
  });

  test("adding an intentional difference sends its owner, reason, scope and an expiry at most 30 days ahead", async ({
    page,
  }) => {
    let body: Record<string, unknown> | null = null;
    await mockApi(page, {
      handlers: handlers([
        async (route, url) => {
          if (
            route.request().method() !== "POST" ||
            url.pathname !== "/v1/shadow/differences"
          )
            return false;
          body = route.request().postDataJSON() as Record<string, unknown>;
          await json(route, 201, difference("sdf_01hzx3k5v7m9p2q4r6s8t0w2y6"));
          return true;
        },
      ]),
    });
    await page.goto("/console/migration/shadow");
    await page.getByLabel("Layer").selectOption("routing");
    await page.getByLabel("Template", { exact: true }).fill("welcome");
    await page.getByLabel("Owner").fill("team-growth");
    await page.getByLabel("Expires in (days, 1 to 30)").fill("31");
    await page.getByLabel("Reason").fill("Fallback order changed on purpose");
    await expect(page.getByRole("button", { name: "Add" })).toBeDisabled();
    await page.getByLabel("Expires in (days, 1 to 30)").fill("7");
    await expectAccessible(page);
    const before = Date.now();
    await page.getByRole("button", { name: "Add" }).click();
    await expect.poll(() => body).not.toBeNull();
    const sent = body as unknown as Record<string, unknown>;
    expect(sent).toMatchObject({
      layer: "routing",
      field: null,
      template: "welcome",
      channel: null,
      owner: "team-growth",
      reason: "Fallback order changed on purpose",
    });
    const expires = new Date(String(sent.expires_at)).getTime();
    expect(expires - before).toBeGreaterThan(6 * dayMs);
    expect(expires - before).toBeLessThanOrEqual(30 * dayMs);
  });

  test("X-3 renewing an intentional difference goes through the Access step-up", async ({
    page,
  }) => {
    let renewed: Record<string, unknown> | null = null;
    let stepUp = false;
    await mockApi(page, {
      handlers: handlers([
        async (route, url) => {
          if (url.pathname.endsWith("/renew")) {
            renewed = route.request().postDataJSON() as Record<string, unknown>;
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
    await page.goto("/console/migration/shadow");
    const row = page.getByRole("row", { name: /team-ops/ });
    await row.getByRole("button", { name: "Renew" }).click();
    await row.getByLabel("Reason").fill("Still intentional");
    await expectAccessible(page);
    await row.getByRole("button", { name: "Renew" }).click();
    await expect(page).toHaveURL(/stepped=1/);
    expect(stepUp).toBe(true);
    expect(renewed).toMatchObject({ reason: "Still intentional" });
  });
});
