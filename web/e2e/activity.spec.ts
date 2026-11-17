import { expect, test } from "@playwright/test";
import { notification, recipientHandlers } from "./fixtures";
import { expectAccessible, mockApi } from "./mock";

test.describe("X-1 activity", () => {
  test("X-6 every delivery shows its projection, rule_id and sender type in words", async ({
    page,
  }) => {
    await mockApi(page, { handlers: recipientHandlers });
    await page.goto("/console/activity");
    await expect(page.getByText("Sent by an agent")).toBeVisible();
    await expectAccessible(page);

    await page.getByRole("link", { name: /Nov/ }).first().click();
    await expect(page).toHaveURL(
      new RegExp(`/console/activity/notifications/${notification.id}$`),
    );
    const sms = page.locator(
      "[data-delivery='dlv_01hzx3k5v7m9p2q4r6s8t0w2y4']",
    );
    await expect(sms.getByText("Skipped")).toBeVisible();
    await expect(sms.getByText("consent.missing")).toBeVisible();

    const push = page.locator(
      "[data-delivery='dlv_01hzx3k5v7m9p2q4r6s8t0w2y5']",
    );
    await expect(push.getByText("Accepted by the push service")).toBeVisible();
    await expect(push.getByText("Delivered", { exact: true })).toHaveCount(0);
    await expect(push.getByText("Clicked by a likely bot")).toBeVisible();

    await push.getByRole("button", { name: "Show history" }).click();
    await expect(
      push.getByText("Provider acceptance is not delivery.", { exact: false }),
    ).toBeVisible();
    await expect(push.getByRole("cell", { name: "200" }).first()).toBeVisible();
    await expectAccessible(page);
  });

  test("the recipients list masks personal data and offers no export", async ({
    page,
  }) => {
    await mockApi(page, { handlers: recipientHandlers });
    await page.goto("/console/recipients");
    await expect(
      page.getByRole("link", { name: "seed_no_consent" }),
    ).toBeVisible();
    await expect(page.locator("main")).not.toContainText(
      "seed_no_consent@seed",
    );
    await expect(page.getByRole("button", { name: /export/i })).toHaveCount(0);
    await page.getByRole("link", { name: "seed_no_consent" }).click();
    await expect(
      page.getByRole("heading", { name: "Topic subscriptions" }),
    ).toBeVisible();
    await expectAccessible(page);
  });
});
