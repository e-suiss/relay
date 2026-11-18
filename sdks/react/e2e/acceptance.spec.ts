import { expect, test } from "@playwright/test";

test("X-20 turning a preference on and off again takes one click each", async ({ page }) => {
  await page.goto("/demo/?view=preferences&consents=none");
  const cell = page.getByRole("switch", { name: "Offers and news by E-mail" });
  await expect(cell).toHaveAttribute("aria-checked", "false");
  await cell.click();
  await expect(cell).toHaveAttribute("aria-checked", "true");
  await cell.click();
  await expect(cell).toHaveAttribute("aria-checked", "false");
});

test("PC-17 X-20 the three choices carry equal visual weight and none is preselected", async ({
  page,
}) => {
  await page.goto("/demo/?view=preferences");
  await page.getByRole("switch", { name: "Mentions and comments by Push" }).click();
  const step = page.getByTestId("relay-digest-step");
  await expect(step).toBeVisible();
  await expect(step).toBeFocused();
  const choices = step.locator("[data-choice]");
  await expect(choices).toHaveCount(3);
  await expect(choices).toHaveText(["Instant", "Digest", "Never"]);
  const looks = await choices.evaluateAll((buttons) =>
    buttons.map((button) => {
      const style = getComputedStyle(button);
      const box = button.getBoundingClientRect();
      return {
        width: Math.round(box.width),
        height: Math.round(box.height),
        top: Math.round(box.top),
        fontWeight: style.fontWeight,
        fontSize: style.fontSize,
        color: style.color,
        background: style.backgroundColor,
        border: style.borderTopColor + style.borderTopWidth,
        pressed: button.getAttribute("aria-pressed") ?? button.getAttribute("aria-checked"),
      };
    }),
  );
  for (const look of looks.slice(1)) {
    expect(look).toEqual(looks[0]);
  }
  expect(looks[0]?.pressed).toBeNull();
});

test("X-6 statuses never rely on colour alone", async ({ page }) => {
  await page.goto("/demo/?view=inbox");
  const states = page.getByTestId("relay-read-state");
  await expect(states.first()).toBeVisible();
  for (const text of await states.allTextContents()) {
    expect(text).toMatch(/Unread|Read/);
  }
});

test("X-16 delete is reported as hidden and can be undone", async ({ page }) => {
  await page.goto("/demo/?view=inbox");
  const inbox = page.locator(".relay-inbox").last();
  const first = inbox.getByTestId("relay-inbox-item").first();
  await expect(first).toBeVisible();
  const before = await inbox.getByTestId("relay-inbox-item").count();
  await first.getByTestId("relay-delete").click();
  await expect(inbox.getByTestId("relay-inbox-notice")).toContainText("Notification hidden.");
  await inbox.getByTestId("relay-inbox-notice").getByRole("button", { name: "Undo" }).click();
  await expect(inbox.getByTestId("relay-inbox-item")).toHaveCount(before);
});

test("C-24 AG-35 IN-6 the inbox shows the agent label, waitpoint states and approval link", async ({
  page,
}) => {
  await page.goto("/demo/?view=inbox");
  const inbox = page.locator(".relay-inbox").last();
  const item = (id: string) => inbox.locator(`[data-item-id="${id}"]`);
  await expect(item("inb_03")).toBeVisible();
  await expect(item("inb_03").getByTestId("relay-agent-mark")).toHaveText(/Sent by an AI agent/);
  await expect(item("inb_05").getByTestId("relay-agent-mark")).toHaveCount(0);
  await expect(item("inb_03").getByTestId("relay-waitpoint")).toContainText(
    "Waiting for your response",
  );
  await expect(item("inb_06").getByTestId("relay-waitpoint")).toContainText("Answered by you");
  await expect(item("inb_07").getByTestId("relay-waitpoint")).toContainText(
    "No longer expecting a response",
  );
  await expect(item("inb_04").getByTestId("relay-approval-link")).toHaveAttribute(
    "href",
    "https://access.example.com/approvals/77",
  );
  await expect(item("inb_04").getByTestId("relay-waitpoint")).toHaveCount(0);
  await item("inb_03").getByRole("button", { name: "Morning" }).click();
  await expect(item("inb_03").getByTestId("relay-waitpoint")).toContainText("Answered by you");
});

test("X-44 the preference center shows the consents read-only with a link to Access", async ({
  page,
}) => {
  await page.goto("/demo/?view=preferences");
  const section = page.getByTestId("relay-consents");
  await expect(section).toContainText("E-mail: Not given");
  await expect(section).toContainText("SMS: Given");
  await expect(section.getByRole("switch")).toHaveCount(0);
  await expect(section.getByRole("link")).toHaveAttribute(
    "href",
    "https://access.example.com/consents",
  );
  await expect(page.getByTestId("relay-permission-pending").first()).toBeVisible();
});
