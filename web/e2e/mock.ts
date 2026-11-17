import AxeBuilder from "@axe-core/playwright";
import { expect, type Page, type Route } from "@playwright/test";

export const tenant = "ten_01hzx3k5v7m9p2q4r6s8t0w2y4";
export const otherTenant = "ten_01hzx3k5v7m9p2q4r6s8t0w2y5";
export const csrf = "csrf_".padEnd(43, "x");

export const session = {
  object: "operator_session",
  id: "oss_01hzx3k5v7m9p2q4r6s8t0w2y4",
  operator: {
    object: "operator",
    id: "opr_01hzx3k5v7m9p2q4r6s8t0w2y4",
    display_name: "Support Operator",
    status: "active",
    created_at: "2026-11-01T09:00:00Z",
  },
  roles: [
    { role: "tenant_admin", tenant_id: tenant, environment: "live" },
    { role: "tenant_admin", tenant_id: tenant, environment: "test" },
    { role: "tenant_operator", tenant_id: otherTenant, environment: "test" },
  ],
  auth_time: "2026-11-18T08:00:00Z",
  step_up_valid_until: null,
  expires_at: "2026-11-18T20:00:00Z",
  csrf_token: csrf,
};

export interface Seen {
  method: string;
  path: string;
  headers: Record<string, string>;
}

export type Handler = (
  route: Route,
  url: URL,
) => Promise<boolean | undefined> | boolean | undefined;

export function json(route: Route, status: number, body: unknown) {
  return route.fulfill({
    status,
    contentType:
      status >= 400 ? "application/problem+json" : "application/json",
    body: JSON.stringify(body),
  });
}

/** Answers `/v1/*` from fixtures; unknown paths are 404 problems so a missing mock is visible. */
export async function mockApi(
  page: Page,
  options: { signedIn?: boolean; handlers?: Handler[] } = {},
): Promise<Seen[]> {
  const seen: Seen[] = [];
  await page.route("**/v1/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    seen.push({
      method: request.method(),
      path: url.pathname,
      headers: request.headers(),
    });
    for (const handler of options.handlers ?? []) {
      if (await handler(route, url)) return;
    }
    if (url.pathname === "/v1/operator/session" && request.method() === "GET") {
      if (options.signedIn === false) {
        await json(route, 401, {
          type: "https://relay.example/v1/errors/auth_invalid_session",
          title: "Invalid session",
          status: 401,
          code: "auth_invalid_session",
          retryable: false,
        });
        return;
      }
      await json(route, 200, session);
      return;
    }
    await json(route, 404, {
      type: "https://relay.example/v1/errors/resource_not_found",
      title: "Not found",
      status: 404,
      code: "resource_not_found",
      retryable: false,
    });
  });
  return seen;
}

// X-47
export async function expectAccessible(page: Page) {
  const results = await new AxeBuilder({ page })
    .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"])
    .analyze();
  expect(results.violations).toEqual([]);
}
