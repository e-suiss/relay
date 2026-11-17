import { expect, test, type Page } from "@playwright/test";
import { recipientHandlers, sentence, subscriber } from "./fixtures";
import { expectAccessible, mockApi } from "./mock";

const runs = 20;
const p95Budget = 2000;
const interactionBudget = 3;

function percentile(values: number[], p: number): number {
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(
    sorted.length - 1,
    Math.ceil((p / 100) * sorted.length) - 1,
  );
  return sorted[index] ?? Number.POSITIVE_INFINITY;
}

async function answer(page: Page, value: string): Promise<number> {
  let interactions = 0;
  await page.goto("/console/why");
  await page.getByLabel("Phone, email or recipient ID").fill(value);
  interactions += 1;
  await page.getByRole("button", { name: "Find" }).click();
  interactions += 1;
  await expect(page.locator(".answer", { hasText: sentence })).toBeVisible();
  await expect(page.getByText("consent.missing").first()).toBeVisible();
  return interactions;
}

test.describe("X-12 why didn't I receive", () => {
  test("X-45 a support person reaches the rule sentence in at most three interactions and p95 two seconds", async ({
    page,
  }) => {
    await mockApi(page, { handlers: recipientHandlers });
    const durations: number[] = [];
    for (let run = 0; run < runs; run += 1) {
      const value = run % 2 === 0 ? subscriber.phone : subscriber.email;
      const started = Date.now();
      const interactions = await answer(page, value);
      durations.push(Date.now() - started);
      expect(interactions).toBeLessThanOrEqual(interactionBudget);
    }
    const p95 = percentile(durations, 95);
    test.info().annotations.push({
      type: "X-45 p95 ms",
      description: String(p95),
    });
    expect(p95).toBeLessThanOrEqual(p95Budget);
  });

  test("X-5 personal data stays masked and the screen writes no text of its own", async ({
    page,
  }) => {
    await mockApi(page, { handlers: recipientHandlers });
    await answer(page, subscriber.phone);
    const main = page.locator("main");
    await expect(main).not.toContainText(subscriber.email);
    await expect(main).not.toContainText(subscriber.phone);
    await expect(main).not.toContainText(subscriber.name);
    await expect(main).toContainText("+90••••••••33");
    await expect(
      main.locator("[data-rule-id='consent.missing']").first(),
    ).toBeVisible();
    await expectAccessible(page);
  });

  test("X-5 revealing a value asks for a reason and goes through the audited reveal", async ({
    page,
  }) => {
    const seen = await mockApi(page, {
      handlers: [
        ...recipientHandlers,
        async (route, url) => {
          if (
            url.pathname !== `/v1/operator/subscribers/${subscriber.id}/reveal`
          )
            return false;
          await route.fulfill({
            status: 200,
            contentType: "application/json",
            body: JSON.stringify({
              object: "pii_reveal",
              subscriber_id: subscriber.id,
              fields: { phone: subscriber.phone },
              audit_ids: ["aud_01hzx3k5v7m9p2q4r6s8t0w2y4"],
            }),
          });
          return true;
        },
      ],
    });
    await answer(page, subscriber.phone);
    await page.getByRole("button", { name: "Reveal phone" }).click();
    await page.getByLabel("Reason").fill("Ticket 4711: customer asked why");
    await page.getByRole("button", { name: "Reveal", exact: true }).click();
    await expect(page.locator("main")).toContainText(subscriber.phone);
    const reveal = seen.find((item) => item.path.endsWith("/reveal"));
    expect(reveal?.method).toBe("POST");
    expect(reveal?.headers["relay-csrf-token"]).toBeTruthy();
    expect(reveal?.headers["idempotency-key"]).toBeTruthy();
  });

  test("an unknown phone number says no recipient matches", async ({
    page,
  }) => {
    await mockApi(page, { handlers: recipientHandlers });
    await page.goto("/console/why");
    await page.getByLabel("Phone, email or recipient ID").fill("+905550000000");
    await page.getByRole("button", { name: "Find" }).click();
    await expect(
      page.getByText(
        "No recipient matches this value in this tenant and environment.",
      ),
    ).toBeVisible();
  });
});
