import { expect, test } from "@playwright/test";
import { expectAccessible, json, mockApi, type Handler } from "./mock";

const list = (data: unknown[]) => ({
  object: "list",
  has_more: false,
  next_cursor: null,
  data,
});

const stamp = "2026-11-17T09:00:00Z";

function workflow(overrides: Record<string, unknown> = {}) {
  return {
    object: "workflow",
    id: "wfl_01hzx3k5v7m9p2q4r6s8t0w2y4",
    key: "welcome",
    name: "Welcome",
    managed_by: "panel",
    published_version: 2,
    draft: {
      name: "Welcome",
      category: "account",
      message_class: "transactional",
      event_schema: {
        type: "object",
        properties: { plan: { type: "string" } },
      },
      steps: [
        {
          type: "channel",
          key: "email_1",
          channel: "email",
          template: "welcome-mail",
        },
      ],
    },
    last_publication: {
      status: "published",
      version: 2,
      requested_at: stamp,
      finished_at: stamp,
    },
    state: "active",
    version: 3,
    created_at: stamp,
    updated_at: stamp,
    ...overrides,
  };
}

const versions = list([
  {
    object: "workflow_version",
    id: "wfv_01hzx3k5v7m9p2q4r6s8t0w2y4",
    workflow_key: "welcome",
    version: 2,
    definition: workflow().draft,
    definition_digest: "a".repeat(64),
    promoted_from: null,
    published_at: stamp,
    published_by: "opr_01hzx3k5v7m9p2q4r6s8t0w2y4",
  },
  {
    object: "workflow_version",
    id: "wfv_01hzx3k5v7m9p2q4r6s8t0w2y3",
    workflow_key: "welcome",
    version: 1,
    definition: workflow().draft,
    definition_digest: "b".repeat(64),
    promoted_from: null,
    published_at: stamp,
    published_by: "opr_01hzx3k5v7m9p2q4r6s8t0w2y4",
  },
]);

function common(extra: Record<string, unknown>): Handler {
  const fixed: Record<string, unknown> = {
    "/v1/routes": list([
      {
        object: "route",
        id: "rte_01hzx3k5v7m9p2q4r6s8t0w2y4",
        key: "critical_alert",
        name: "Critical alert",
        tree: {
          escalate: {
            unless: "seen",
            ladder: [
              { after: "PT5M", node: "push" },
              { after: "PT30M", node: "sms" },
            ],
          },
        },
        state: "active",
        version: 1,
        created_at: stamp,
        updated_at: stamp,
        archived_at: null,
      },
    ]),
    "/v1/templates": list([]),
    "/v1/categories": list([
      {
        object: "category",
        id: "ctg_01hzx3k5v7m9p2q4r6s8t0w2y4",
        key: "account",
        name: "Account",
        message_class: "transactional",
        locked: false,
        enabled: true,
      },
    ]),
    "/v1/workflows/welcome/versions": versions,
    "/v1/notifications": list([
      {
        object: "notification",
        id: "ntf_01hzx3k5v7m9p2q4r6s8t0w2y4",
        event_id: "evt_01hzx3k5v7m9p2q4r6s8t0w2y4",
        workflow: { key: "welcome", version: 1 },
        recipient_id: "sub_01hzx3k5v7m9p2q4r6s8t0w2y4",
        external_id: "u1",
        message_class: "transactional",
        sender_type: "system",
        state: "active",
        close_rule_id: null,
        delivery_counts: {},
        is_test: false,
        created_at: stamp,
        updated_at: stamp,
      },
    ]),
    "/v1/campaigns": list([]),
    "/v1/test_recipients": list([]),
    "/v1/operator/send_modes": {
      object: "list",
      has_more: false,
      next_cursor: null,
      data: [
        {
          object: "send_mode_setting",
          level: "category_channel",
          category: "account",
          channel: "email",
          mode: "shadow",
          updated_at: stamp,
          updated_by: "opr_01hzx3k5v7m9p2q4r6s8t0w2y4",
        },
      ],
    },
    ...extra,
  };
  return async (route, url) => {
    if (route.request().method() !== "GET") return false;
    const body = fixed[url.pathname];
    if (body === undefined) return false;
    await json(route, 200, body);
    return true;
  };
}

test.describe("X-10 visual workflow editor", () => {
  test("WF-3 a step added from the palette is saved as the draft and publish waits for the gate", async ({
    page,
  }) => {
    let current = workflow();
    let publishable = false;
    let ifMatch: string | undefined;
    const handlers: Handler[] = [
      async (route, url) => {
        const method = route.request().method();
        if (url.pathname === "/v1/workflows/welcome" && method === "GET") {
          await json(route, 200, current);
          return true;
        }
        if (url.pathname === "/v1/workflows/welcome" && method === "PUT") {
          ifMatch = route.request().headers()["if-match"];
          const body = route.request().postDataJSON() as {
            definition: Record<string, unknown>;
          };
          current = workflow({ draft: body.definition, version: 4 });
          publishable = true;
          await json(route, 200, current);
          return true;
        }
        if (url.pathname === "/v1/workflows/welcome/publication_check") {
          await json(route, 200, {
            object: "workflow_publication_check",
            publishable,
            errors: publishable
              ? []
              : [
                  {
                    pointer: "/steps/0/template",
                    code: "not_found",
                    detail: "template welcome-mail has no live version",
                  },
                ],
          });
          return true;
        }
        if (url.pathname === "/v1/workflows/welcome/versions/1/mermaid") {
          await route.fulfill({
            status: 200,
            contentType: "text/plain",
            body: "flowchart TD\n  email_1",
          });
          return true;
        }
        return false;
      },
      common({}),
    ];
    await mockApi(page, { handlers });
    await page.goto("/console/workflows/welcome");
    await expect(
      page.getByRole("heading", { level: 1, name: "Welcome" }),
    ).toBeVisible();
    await expect(page.locator("[data-gate='fail']")).toBeVisible();
    await expect(
      page.locator("[data-gate-error='/steps/0/template']"),
    ).toBeVisible();
    await expect(page.locator("[data-publish]")).toBeDisabled();
    await expectAccessible(page);

    for (const type of [
      "channel",
      "delay",
      "digest",
      "throttle",
      "condition",
      "wait_for_event",
      "time_window",
      "webhook",
    ])
      await expect(page.locator(`[data-palette='${type}']`)).toBeVisible();

    await page.getByRole("button", { name: "Add a step here" }).last().click();
    await page.getByLabel("Choose a step").selectOption("delay");
    await expect(page.locator("[data-inspector='delay_1']")).toBeVisible();
    await page.getByLabel("Wait for", { exact: true }).fill("PT2H");
    await expect(page.locator("[data-inspector='delay_1']")).toContainText(
      "2h",
    );

    await page.getByRole("button", { name: "Save draft" }).click();
    await expect(page.getByText("Draft saved.")).toBeVisible();
    expect(ifMatch).toBe('"3"');
    await expect(page.locator("[data-gate='pass']")).toBeVisible();
    await expect(page.locator("[data-publish]")).toBeEnabled();

    await expect(page.locator("[data-used-version]").first()).toHaveText("v1");
    await expect(page.locator("[data-send-mode='email']")).toContainText(
      "shadow",
    );
    await expect(page.locator("[data-promote='1']")).toBeVisible();
    await page.getByRole("button", { name: "Mermaid of v1" }).click();
    await expect(page.locator("[data-mermaid='1']")).toContainText(
      "flowchart TD",
    );
    await expectAccessible(page);
  });

  test("X-9 a code-managed workflow shows the lock and edits only its control fields", async ({
    page,
  }) => {
    const locked = workflow({
      managed_by: "code",
      draft: {
        ...workflow().draft,
        controls: ["/steps/0/template"],
      },
    });
    await mockApi(page, {
      handlers: [
        async (route, url) => {
          if (url.pathname === "/v1/workflows/welcome") {
            await json(route, 200, locked);
            return true;
          }
          if (url.pathname === "/v1/workflows/welcome/publication_check") {
            await json(route, 404, {
              type: "https://relay.example/v1/errors/resource_not_found",
              title: "Not found",
              status: 404,
              code: "resource_not_found",
            });
            return true;
          }
          return false;
        },
        common({}),
      ],
    });
    await page.goto("/console/workflows/welcome");
    await expect(page.locator("[data-code-managed]")).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Add a step here" }),
    ).toHaveCount(0);
    await expect(page.locator("[data-gate-mode='fallback']")).toBeVisible();
    await page.locator("[data-step='email_1'] .step-select").click();
    await expect(
      page.locator("[data-pointer='/steps/0/template']"),
    ).toBeEnabled();
    await expect(
      page.locator("[data-pointer='/steps/0/channel']"),
    ).toBeDisabled();
    await expect(page.locator("[data-pointer='/steps/0/key']")).toBeDisabled();
    await expectAccessible(page);
  });
});

test.describe("AG-17 escalation policy editor", () => {
  test("a new policy is built from tiers on a timeline and saved as its first version", async ({
    page,
  }) => {
    let saved: Record<string, unknown> | null = null;
    let ifMatch: string | undefined = "unset";
    await mockApi(page, {
      handlers: [
        async (route, url) => {
          if (url.pathname !== "/v1/escalation_policies/on-call") return false;
          if (route.request().method() === "PUT") {
            ifMatch = route.request().headers()["if-match"];
            saved = route.request().postDataJSON() as Record<string, unknown>;
            await json(route, 200, {
              object: "escalation_policy",
              id: "esp_01hzx3k5v7m9p2q4r6s8t0w2y4",
              key: "on-call",
              version: 1,
              state: "active",
              description: null,
              tiers: saved.tiers,
              created_at: stamp,
              updated_at: stamp,
            });
            return true;
          }
          await json(route, 404, {
            type: "https://relay.example/v1/errors/resource_not_found",
            title: "Not found",
            status: 404,
            code: "resource_not_found",
          });
          return true;
        },
        common({
          "/v1/escalation_policies": list([]),
          "/v1/escalation_policies/on-call/versions": list([]),
          "/v1/escalation_policies/on-call/usage": {
            object: "escalation_policy_usage",
            policy_key: "on-call",
            latest_version: 1,
            versions: [{ version: 1, open: 2, stalled: 0 }],
          },
        }),
      ],
    });
    await page.goto("/console/escalation");
    await expect(page.locator("[data-escalate]")).toContainText(
      "Escalate unless seen",
    );
    await page.getByLabel("Policy key").fill("on-call");
    await page.getByRole("button", { name: "New policy" }).click();
    await expect(page).toHaveURL(/\/console\/escalation\/policies\/on-call$/);
    await page.getByRole("button", { name: "Add a tier" }).click();
    const second = page.locator("[data-tier='1']");
    await second.getByLabel("Opens after the previous tier by").fill("PT8H");
    await second.getByRole("checkbox", { name: "SMS" }).check();
    await second.getByRole("button", { name: "Add a responder" }).click();
    await second.getByLabel("Responder 1", { exact: true }).fill("user-c");
    await expect(page.locator("[data-opens-at='32400']")).toBeVisible();
    await expectAccessible(page);
    await page.getByRole("button", { name: "Save as a new version" }).click();
    await expect(page.getByText("Saved as v1.")).toBeVisible();
    expect(ifMatch).toBeUndefined();
    expect(saved).toEqual({
      tiers: [
        { after: "PT1H", repeat: 0, skip_if_empty: true },
        {
          after: "PT8H",
          repeat: 0,
          skip_if_empty: true,
          channels: ["sms"],
          add_responders: [{ kind: "subscriber", id: "user-c" }],
        },
      ],
    });
    await expect(page.locator("[data-policy-usage]")).toContainText("2 open");
  });
});

const template = {
  object: "template",
  id: "tpl_01hzx3k5v7m9p2q4r6s8t0w2y4",
  key: "welcome-mail",
  name: "Welcome mail",
  owner: "tenant",
  product: null,
  subtenant: null,
  category: "account",
  message_class: "transactional",
  type: "transactional",
  protected: false,
  state: "active",
  live_version: 1,
  draft: {
    default_locale: "tr-TR",
    transliterate: false,
    allow_raw: false,
    cells: {
      email: {
        "tr-TR": {
          subject: "Hoş geldiniz",
          html_kind: "mjml",
          html: "<mj-text>Hesabınız hazır.</mj-text>",
          text: "Hesabınız hazır.",
        },
      },
    },
  },
  draft_checksum: "c".repeat(64),
  version: 5,
  created_at: stamp,
  updated_at: stamp,
};

test.describe("TP-38 template editor and channel previews", () => {
  test("TP-10 the SMS draft from the e-mail is an editable draft and previews are channel faithful", async ({
    page,
  }) => {
    await page.route("https://preview.relay.test/**", (route) =>
      route.fulfill({
        status: 200,
        contentType: "text/html",
        body: '<!doctype html><html lang="tr"><head><title>Önizleme</title></head><body><p>Hesabınız hazır.</p></body></html>',
      }),
    );
    await mockApi(page, {
      handlers: [
        async (route, url) => {
          if (url.pathname === "/v1/templates/welcome-mail") {
            await json(route, 200, template);
            return true;
          }
          if (url.pathname === "/v1/templates/welcome-mail/publication_check") {
            await json(route, 200, {
              object: "template_publication_check",
              publishable: true,
              checksum: "c".repeat(64),
              findings: [
                {
                  check: "plain_text_short",
                  level: "warning",
                  channel: "email",
                  locale: "tr-TR",
                  message: "The plain text is much shorter than the HTML.",
                },
              ],
            });
            return true;
          }
          if (url.pathname === "/v1/templates/welcome-mail/preview") {
            await json(route, 200, {
              object: "template_preview",
              template_key: "welcome-mail",
              version: "draft",
              sample: "boundary",
              renders: [
                {
                  channel: "email",
                  locale: "tr-TR",
                  content: {
                    subject: "Hoş geldiniz",
                    html: null,
                    text: "Hesabınız hazır.",
                  },
                  warnings: [],
                  measures: { bytes: 75_000 },
                  sandbox_url: "https://preview.relay.test/sandbox/abc",
                },
                {
                  channel: "sms",
                  locale: "tr-TR",
                  content: { body: "Siparişiniz yolda" },
                  warnings: [],
                  sms: {
                    encoding: "GSM7_TR",
                    encoding_unverified_provider: "UCS2",
                    segments: 1,
                    characters: 17,
                  },
                },
                {
                  channel: "push",
                  locale: "tr-TR",
                  content: { title: "Hoş geldiniz", body: "Hesabınız hazır." },
                  warnings: [],
                },
              ],
            });
            return true;
          }
          return false;
        },
        common({
          "/v1/templates/welcome-mail/translations": {
            object: "template_translations",
            template_key: "welcome-mail",
            source: "draft",
            version: null,
            default_locale: "tr-TR",
            locales: ["tr-TR", "en-GB"],
            cells: [
              { channel: "email", locale: "tr-TR", status: "present" },
              { channel: "email", locale: "en-GB", status: "missing" },
            ],
          },
          "/v1/workflows": list([workflow()]),
        }),
      ],
    });
    await page.goto("/console/templates/welcome-mail");
    await expect(page.locator("[data-cell='email:en-GB']")).toContainText(
      "Missing",
    );
    await expect(page.locator("[data-finding='warning']")).toBeVisible();
    await expect(page.locator("[data-publish]")).toBeDisabled();
    await page
      .getByRole("checkbox", { name: "Publish despite the warnings" })
      .check();
    await expect(page.locator("[data-publish]")).toBeEnabled();

    await page.locator("[data-cell='sms:tr-TR']").click();
    await page.getByRole("button", { name: "Write a variant" }).click();
    await page.locator("[data-helper='sms-from-email']").click();
    const body = page.locator(
      "[data-cell-editor='sms:tr-TR'] [data-field='body']",
    );
    await expect(body).toHaveValue("Hoş geldiniz\nHesabınız hazır.");
    await body.fill("Hoş geldiniz!");
    await expect(page.getByText("It is not linked")).toBeVisible();
    await expect(page.locator("[data-publish]")).toBeDisabled();

    await page.locator("[data-plural-helper] summary").click();
    await expect(page.locator("[data-plural-category]")).toHaveCount(2);
    await expectAccessible(page);

    await page.getByLabel("Workflow", { exact: true }).selectOption("welcome");
    await page.getByRole("button", { name: "Render" }).click();
    const frame = page.locator("iframe.sandbox-frame");
    await expect(frame).toHaveAttribute("sandbox", "");
    await expect(frame).toHaveAttribute(
      "src",
      "https://preview.relay.test/sandbox/abc",
    );
    await expect(page.locator("[data-email-size]")).toContainText("73.2 KB");
    await expect(page.locator("[data-sms-encoding]")).toHaveText("GSM7_TR");
    await expect(page.locator("[data-preview='push']")).toContainText(
      "iOS lock screen",
    );
    await page.locator("[data-preview='sms'] summary").click();
    await expect(page.locator("[data-transliterated]")).toContainText("GSM7");
    await page
      .locator("[data-preview='email']")
      .getByRole("button", { name: "Plain text" })
      .click();
    await expect(frame).toHaveCount(0);
    await expect(page.locator("[data-preview='email'] pre")).toHaveText(
      "Hesabınız hazır.",
    );
    await expectAccessible(page);
  });
});

test.describe("X-52 test inbox", () => {
  test("X-43 shows rendered test messages, digest-only security messages and resets the seeds", async ({
    page,
  }) => {
    let reset = false;
    await mockApi(page, {
      handlers: [
        async (route, url) => {
          if (url.pathname === "/v1/test/seed-recipients/reset") {
            reset = true;
            await json(route, 202, { object: "seed_reset", status: "queued" });
            return true;
          }
          return false;
        },
        common({
          "/v1/test/inbox": list([
            {
              object: "test_inbox_message",
              notification_id: "ntf_01hzx3k5v7m9p2q4r6s8t0w2y4",
              event_id: null,
              recipient_id: "sub_01hzx3k5v7m9p2q4r6s8t0w2y4",
              workflow: { key: "welcome", version: 2 },
              message_class: "transactional",
              state: "active",
              close_rule_id: null,
              created_at: stamp,
              deliveries: [
                {
                  delivery_id: "dlv_01hzx3k5v7m9p2q4r6s8t0w2y4",
                  channel: "sms",
                  status: "sent",
                  gates: "passed",
                  decisions: [],
                  render: {
                    content_digest: "d".repeat(64),
                    digest_only: null,
                    locale: "tr-TR",
                    output: { body: "Hoş geldiniz" },
                    rendered_at: stamp,
                  },
                },
                {
                  delivery_id: "dlv_01hzx3k5v7m9p2q4r6s8t0w2y5",
                  channel: "email",
                  status: "skipped",
                  rule_id: "consent.missing",
                  gates: "stopped",
                  decisions: [],
                  render: {
                    content_digest: "e".repeat(64),
                    digest_only: "security_subtype",
                    locale: null,
                    output: null,
                    rendered_at: stamp,
                  },
                },
              ],
            },
          ]),
          "/v1/test/seed-recipients": list([
            {
              object: "seed_recipient",
              external_id: "seed_no_consent",
              email: "seed_no_consent@seed.relay.test",
              phone: "+990555100001",
              email_result: "delivered",
              description: "No marketing consent",
              set_up: true,
            },
          ]),
          "/v1/test/simulated-results": list([]),
        }),
      ],
    });
    await page.goto("/console/test-inbox");
    await expect(page.locator("[data-live-plane]")).toBeVisible();
    await page.getByLabel("Environment", { exact: true }).selectOption("test");
    await expect(page.locator("[data-test-message]")).toBeVisible();
    await expect(page.locator("[data-preview='sms']")).toContainText(
      "Hoş geldiniz",
    );
    await expect(
      page.locator("[data-digest-only='security_subtype']"),
    ).toBeVisible();
    await expect(page.getByText("consent.missing")).toBeVisible();
    await expect(page.getByText("No marketing consent").first()).toBeVisible();
    await page.locator("[data-reset-seeds]").click();
    await expect(page.getByText("The reset is queued.")).toBeVisible();
    expect(reset).toBe(true);
    await expectAccessible(page);
  });
});
