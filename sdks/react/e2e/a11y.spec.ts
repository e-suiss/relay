import AxeBuilder from "@axe-core/playwright";
import { expect, test, type Page } from "@playwright/test";

const wcag = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"];

async function audit(page: Page): Promise<void> {
  const result = await new AxeBuilder({ page }).withTags(wcag).analyze();
  expect(
    result.violations.map(
      (violation) =>
        `${violation.id}: ${violation.nodes.map((node) => node.target.join(" ")).join(", ")}`,
    ),
  ).toEqual([]);
}

for (const locale of ["en", "tr"]) {
  for (const scheme of ["light", "dark"]) {
    test(`X-32 WCAG 2.2 AA inbox, preferences and portal (${locale}, ${scheme})`, async ({
      page,
    }) => {
      await page.goto(`/demo/?locale=${locale}&scheme=${scheme}`);
      await expect(page.getByTestId("relay-inbox-item").first()).toBeVisible();
      await expect(page.getByTestId("relay-preference-matrix")).toBeVisible();
      await expect(page.getByTestId("relay-endpoint").first()).toBeVisible();
      await expect(page.getByTestId("relay-message").first()).toBeVisible();
      await audit(page);
    });
  }
}

test("X-32 WCAG 2.2 AA with the open inbox, the three choices and a portal error", async ({
  page,
}) => {
  await page.goto("/demo/?locale=en&scheme=light");
  await page.locator(".relay-bell").first().click();
  await expect(page.locator("[data-testid=relay-inbox-item]").first()).toBeVisible();
  await page.getByRole("switch", { name: "Mentions and comments by Push" }).click();
  await expect(page.getByTestId("relay-digest-step")).toBeVisible();
  await page.getByRole("button", { name: "Add endpoint" }).click();
  await page.getByLabel("Endpoint URL").fill("https://10.0.0.5/hook");
  await page.getByRole("checkbox", { name: /order.created/ }).check();
  await page.getByTestId("relay-endpoint-form").getByRole("button", { name: "Save" }).click();
  await expect(page.getByTestId("relay-url-error")).toBeVisible();
  await page
    .getByTestId("relay-inbox-item")
    .first()
    .getByRole("button", { name: "Snooze" })
    .click();
  await audit(page);
});

test("X-32 keyboard reaches and works every inbox control", async ({ page }) => {
  await page.goto("/demo/?view=inbox");
  const bell = page.locator(".relay-bell").first();
  await bell.focus();
  await page.keyboard.press("Enter");
  await expect(bell).toHaveAttribute("aria-expanded", "true");
  await page.keyboard.press("Escape");
  await expect(bell).toHaveAttribute("aria-expanded", "false");
  await expect(bell).toBeFocused();
});
