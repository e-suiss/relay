import { expect, test } from "@playwright/test";
import { expectAccessible, mockApi, otherTenant, tenant } from "./mock";

test.describe("X-47 console shell", () => {
  test("a signed-out visitor is offered the Access sign-in with a way back", async ({
    page,
  }) => {
    await mockApi(page, { signedIn: false });
    await page.goto("/console/why");
    const link = page.getByRole("link", { name: "Sign in with Access" });
    await expect(link).toHaveAttribute(
      "href",
      "/v1/operator/session/login?return_to=%2Fconsole%2Fwhy",
    );
    await expectAccessible(page);
  });

  test("X-4 the tenant, environment and subtenant are visible on every page", async ({
    page,
  }) => {
    await mockApi(page);
    await page.goto("/console/");
    await expect(page).toHaveURL(/\/console\/activity$/);
    for (const name of ["Workflows", "Templates and layouts", "Audit log"]) {
      await page
        .getByRole("navigation", { name: "Console sections" })
        .getByRole("link", { name })
        .click();
      await expect(page.getByRole("heading", { level: 1, name })).toBeVisible();
      await expect(page.getByLabel("Tenant", { exact: true })).toHaveValue(tenant);
      await expect(page.getByLabel("Environment", { exact: true })).toBeVisible();
      await expect(page.getByLabel("Subtenant", { exact: true })).toBeVisible();
    }
    await expectAccessible(page);
  });

  test("X-4 the context goes with every API request", async ({ page }) => {
    const seen = await mockApi(page);
    await page.goto("/console/activity");
    await page.getByLabel("Tenant", { exact: true }).selectOption(otherTenant);
    await expect(page.getByLabel("Environment", { exact: true })).toHaveValue("test");
    await page.reload();
    await expect(page.getByLabel("Tenant", { exact: true })).toHaveValue(otherTenant);
    expect(seen.some((item) => item.path === "/v1/operator/session")).toBe(
      true,
    );
  });

  test("the W2 editor slots are routed", async ({ page }) => {
    await mockApi(page);
    for (const path of [
      "/console/workflows",
      "/console/templates/welcome",
      "/console/escalation",
      "/console/test-inbox",
    ]) {
      await page.goto(path);
      await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
      await expect(page.getByText("Page not found")).toHaveCount(0);
    }
  });

  test("an unknown console path says so", async ({ page }) => {
    await mockApi(page);
    await page.goto("/console/nowhere");
    await expect(
      page.getByRole("heading", { name: "Page not found" }),
    ).toBeVisible();
  });

  test("the console follows the chosen language and theme", async ({
    page,
  }) => {
    await mockApi(page);
    await page.goto("/console/activity");
    await page.getByLabel("Language", { exact: true }).selectOption("tr");
    await expect(page.locator("html")).toHaveAttribute("lang", "tr");
    await expect(page.getByLabel("Kiracı", { exact: true })).toBeVisible();
    await page.getByLabel("Tema", { exact: true }).selectOption("dark");
    await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
    await expectAccessible(page);
  });
});
