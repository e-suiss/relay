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
    test(`X-32 WCAG 2.2 AA of the web components (${locale}, ${scheme})`, async ({ page }) => {
      await page.goto(`/demo/?locale=${locale}&scheme=${scheme}`);
      await expect(
        page.locator("relay-inbox").getByTestId("relay-inbox-item").first(),
      ).toBeVisible();
      await expect(
        page.locator("relay-preference-center").getByTestId("relay-preference-matrix"),
      ).toBeVisible();
      await expect(
        page.locator("relay-webhook-portal").getByTestId("relay-endpoint").first(),
      ).toBeVisible();
      await audit(page);
    });
  }
}

test("X-32 the page's CSS custom properties theme an element", async ({ page }) => {
  await page.goto("/demo/");
  const matrix = page.locator("relay-preference-center").getByTestId("relay-preference-matrix");
  await expect(matrix).toBeVisible();
  const accent = await page
    .locator("relay-preference-center")
    .locator(".relay-root")
    .evaluate((element) =>
      getComputedStyle(element).getPropertyValue("--relay-color-accent").trim(),
    );
  expect(accent).toBe("#0b5c3b");
});

test("PC-17 the three choices work inside the shadow root", async ({ page }) => {
  await page.goto("/demo/");
  const center = page.locator("relay-preference-center");
  await center.getByRole("switch", { name: "Mentions and comments by Push" }).click();
  const step = center.getByTestId("relay-digest-step");
  await expect(step.locator("[data-choice]")).toHaveText(["Instant", "Digest", "Never"]);
  await audit(page);
});

test("X-16 the inbox shortcut focuses the category in the preference center", async ({ page }) => {
  await page.goto("/demo/");
  const inbox = page.locator("relay-inbox");
  await inbox
    .getByTestId("relay-inbox-item")
    .first()
    .getByTestId("relay-category-shortcut")
    .click();
  await expect(page.locator("relay-preference-center")).toHaveAttribute("focus-category", "orders");
});
