import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import type { ReactElement } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { RelayProvider, type RelayLinks } from "../src/context.js";
import { Bell } from "../src/inbox/Bell.js";
import { Inbox } from "../src/inbox/Inbox.js";
import { WebhookPortal } from "../src/portal/WebhookPortal.js";
import { PreferenceCenter } from "../src/preferences/PreferenceCenter.js";
import type { ConsentView } from "../src/seams.js";
import { createFakeRelay, demoRelay, fakeItem, type FakeRelay } from "../src/testing/index.js";

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

const links: RelayLinks = {
  accessConsentUrl: "https://access.example.com/consents",
  accessApprovalOrigin: "https://access.example.com",
};

function renderWith(
  relay: FakeRelay,
  ui: ReactElement,
  extra: { links?: RelayLinks; locale?: string } = {},
) {
  return render(
    <RelayProvider
      baseUrl="https://relay.example.com"
      token={relay.token}
      portalToken={relay.portalToken}
      fetch={relay.fetch}
      realtime={false}
      tabs={false}
      storage={null}
      undoWindowMs={50}
      locale={extra.locale ?? "en"}
      colorScheme="light"
      links={extra.links ?? links}
    >
      {ui}
    </RelayProvider>,
  );
}

function intents(relay: FakeRelay, op: string) {
  return relay.requests.filter(
    (request) => request.path.endsWith("/intents") && request.body?.op === op,
  );
}

describe("X-16 X-17 inbox", () => {
  it("X-16 lists items with their read state as text", async () => {
    const relay = createFakeRelay({
      items: [
        fakeItem("inb_1", { title: "Hello" }),
        fakeItem("inb_2", { title: "Old", read: true, seen: true }),
      ],
    });
    renderWith(relay, <Inbox />);
    const items = await screen.findAllByTestId("relay-inbox-item");
    expect(items).toHaveLength(2);
    expect(within(items[0] as HTMLElement).getByTestId("relay-read-state").textContent).toContain(
      "Unread",
    );
    expect(within(items[1] as HTMLElement).getByTestId("relay-read-state").textContent).toContain(
      "Read",
    );
  });

  it("X-16 delete hides the item and tells the user it was hidden", async () => {
    const relay = createFakeRelay({ items: [fakeItem("inb_1", { title: "Hello" })] });
    renderWith(relay, <Inbox />);
    fireEvent.click(await screen.findByTestId("relay-delete"));
    expect(screen.getByTestId("relay-inbox-notice").textContent).toContain("Notification hidden.");
    await waitFor(() => expect(intents(relay, "hide")).toHaveLength(1));
    expect(relay.state.items[0]?.hidden).toBe(true);
  });

  it("IN-15 undo keeps the hide from being sent", async () => {
    const relay = createFakeRelay({ items: [fakeItem("inb_1", { title: "Hello" })] });
    renderWith(relay, <Inbox />);
    fireEvent.click(await screen.findByTestId("relay-delete"));
    fireEvent.click(screen.getByRole("button", { name: "Undo" }));
    await new Promise((resolve) => setTimeout(resolve, 120));
    expect(intents(relay, "hide")).toHaveLength(0);
    expect(screen.getAllByTestId("relay-inbox-item")).toHaveLength(1);
  });

  it("X-17 mark all as read lowers the badge at once and sends one request after the undo window", async () => {
    const relay = createFakeRelay({ items: [fakeItem("inb_1"), fakeItem("inb_2")] });
    renderWith(
      relay,
      <>
        <Bell badgeSource="unread" />
        <Inbox />
      </>,
    );
    await screen.findAllByTestId("relay-inbox-item");
    await waitFor(() => expect(screen.getByTestId("relay-badge").textContent).toBe("2"));
    fireEvent.click(screen.getByTestId("relay-mark-all-read"));
    expect(screen.queryByTestId("relay-badge")).toBeNull();
    expect(relay.requests.some((request) => request.path.endsWith("/read_all"))).toBe(false);
    await waitFor(() =>
      expect(relay.requests.filter((request) => request.path.endsWith("/read_all"))).toHaveLength(
        1,
      ),
    );
    expect(relay.requests.some((request) => request.body?.op === "archive")).toBe(false);
  });

  it("X-16 the shortcut opens the item's category preferences", async () => {
    const relay = createFakeRelay({ items: [fakeItem("inb_1", { category: "orders" })] });
    const open = vi.fn();
    renderWith(relay, <Inbox />, { links: { ...links, onOpenPreferences: open } });
    fireEvent.click(await screen.findByTestId("relay-category-shortcut"));
    expect(open).toHaveBeenCalledWith("orders");
  });

  it("C-24 marks an agent-sourced item", async () => {
    const relay = createFakeRelay({
      items: [
        fakeItem("inb_1", { sender_type: "agent" }),
        fakeItem("inb_2", { sender_type: "human" }),
      ],
    });
    renderWith(relay, <Inbox />);
    await screen.findAllByTestId("relay-inbox-item");
    expect(screen.getAllByTestId("relay-agent-mark")).toHaveLength(1);
    expect(screen.getByTestId("relay-agent-mark").textContent).toContain("Sent by an AI agent");
  });

  it("IN-6 an approval item only links to the Access approval surface", async () => {
    const relay = createFakeRelay({
      items: [
        fakeItem("inb_1", {
          approval: true,
          actions: [
            { label: "Approve", url: "https://shop.example.com/approve" },
            { label: "Review", url: "https://access.example.com/approvals/7" },
          ],
        }),
      ],
    });
    renderWith(relay, <Inbox />);
    const link = await screen.findByTestId("relay-approval-link");
    expect(link.getAttribute("href")).toBe("https://access.example.com/approvals/7");
    expect(screen.queryByText("Approve")).toBeNull();
  });

  it("AG-35 an awaiting response goes from processing to answered", async () => {
    const relay = createFakeRelay({
      items: [
        fakeItem("inb_1", {
          waitpoint: {
            id: "wp_1",
            status: "awaiting",
            subject_digest: "d1",
            options: [{ label: "Yes", value: true }],
          },
        }),
      ],
    });
    renderWith(relay, <Inbox />);
    expect((await screen.findByTestId("relay-waitpoint")).textContent).toContain(
      "Waiting for your response",
    );
    fireEvent.click(screen.getByRole("button", { name: "Yes" }));
    expect(screen.getByTestId("relay-waitpoint").textContent).toContain("Processing your response");
    await waitFor(() =>
      expect(screen.getByTestId("relay-waitpoint").textContent).toContain("Answered by you"),
    );
    const request = relay.requests.find(
      (entry) => entry.path === "/v1/subscriber/waitpoints/wp_1/response",
    );
    expect(request?.body).toEqual({ response: true, subject_digest: "d1" });
  });

  it("AG-35 shows when a response is no longer expected", async () => {
    const relay = createFakeRelay({
      items: [fakeItem("inb_1", { waitpoint: { id: "wp_1", status: "not_awaited" } })],
    });
    renderWith(relay, <Inbox />);
    expect((await screen.findByTestId("relay-waitpoint")).textContent).toContain(
      "No longer expecting a response",
    );
  });

  it("X-32 renders Turkish texts", async () => {
    const relay = createFakeRelay({ items: [fakeItem("inb_1")] });
    renderWith(relay, <Inbox />, { locale: "tr-TR" });
    expect(await screen.findByRole("heading", { name: "Bildirimler" })).toBeTruthy();
    expect(screen.getByTestId("relay-delete").textContent).toBe("Sil");
  });
});

describe("§8.7 preference center", () => {
  const consents = (): Promise<readonly ConsentView[] | null> =>
    Promise.resolve([{ channel: "email", status: "none" }]);

  it("PC-6 X-22 shows locked categories with whom the lock serves", async () => {
    renderWith(demoRelay(), <PreferenceCenter consents={consents} />);
    await screen.findByTestId("relay-preference-matrix");
    expect(screen.getAllByText("On (locked)").length).toBeGreaterThan(0);
    expect(screen.getByTestId("relay-lock-reason").textContent).toContain("protects your account");
    expect(screen.getAllByText("Turned off by your administrator")).toHaveLength(1);
    expect(screen.getAllByText("Turned off in device settings")).toHaveLength(1);
  });

  it("X-44 shows Permission pending with a link to Access and never asks for consent", async () => {
    renderWith(demoRelay(), <PreferenceCenter consents={consents} />);
    await screen.findByTestId("relay-preference-matrix");
    const pending = screen.getAllByTestId("relay-permission-pending");
    expect(pending.length).toBeGreaterThan(0);
    expect(
      within(pending[0] as HTMLElement)
        .getByRole("link")
        .getAttribute("href"),
    ).toBe("https://access.example.com/consents");
    const consentSection = screen.getByTestId("relay-consents");
    expect(within(consentSection).queryAllByRole("checkbox")).toHaveLength(0);
    expect(within(consentSection).queryAllByRole("switch")).toHaveLength(0);
    expect(within(consentSection).getByRole("link").getAttribute("href")).toBe(
      "https://access.example.com/consents",
    );
  });

  it("X-44 without a consent source the consent section shows a safe empty state", async () => {
    renderWith(demoRelay(), <PreferenceCenter />);
    await screen.findByTestId("relay-preference-matrix");
    expect(screen.getByTestId("relay-consents").textContent).toContain(
      "Permission details are not shown here.",
    );
    expect(screen.queryAllByTestId("relay-permission-pending")).toHaveLength(0);
  });

  it("PC-17 turning off a digestible cell offers Instant, Digest and Never with none preselected", async () => {
    const relay = demoRelay();
    renderWith(relay, <PreferenceCenter consents={consents} />);
    await screen.findByTestId("relay-preference-matrix");
    fireEvent.click(screen.getByRole("switch", { name: "Mentions and comments by Push" }));
    const step = screen.getByTestId("relay-digest-step");
    const choices = within(step)
      .getAllByRole("button")
      .filter((button) => button.dataset.choice !== undefined);
    expect(choices.map((button) => button.textContent)).toEqual(["Instant", "Digest", "Never"]);
    for (const choice of choices) {
      expect(choice.getAttribute("aria-pressed")).toBeNull();
      expect(choice.getAttribute("aria-checked")).toBeNull();
      expect(choice.className).toBe("relay-choice");
    }
    expect(relay.requests.some((request) => request.method === "PATCH")).toBe(false);
    fireEvent.click(within(step).getByRole("button", { name: "Never" }));
    await waitFor(() =>
      expect(relay.requests.some((request) => request.method === "PATCH")).toBe(true),
    );
    const patch = relay.requests.find((request) => request.method === "PATCH");
    expect(patch?.body).toEqual({
      preferences: [
        { level: "category_channel", category: "social", channel: "push", value: "opt_out" },
      ],
    });
  });

  it("X-20 turning a cell off and on again takes one click each", async () => {
    const relay = demoRelay();
    renderWith(relay, <PreferenceCenter />);
    await screen.findByTestId("relay-preference-matrix");
    const name = "Offers and news by E-mail";
    fireEvent.click(screen.getByRole("switch", { name }));
    await waitFor(() =>
      expect(screen.getByRole("switch", { name }).getAttribute("aria-checked")).toBe("true"),
    );
    await waitFor(() => expect(screen.queryByText("Saved.")).toBeTruthy());
    fireEvent.click(screen.getByRole("switch", { name }));
    await waitFor(() =>
      expect(screen.getByRole("switch", { name }).getAttribute("aria-checked")).toBe("false"),
    );
    await waitFor(() =>
      expect(relay.requests.filter((request) => request.method === "PATCH")).toHaveLength(2),
    );
  });

  it("X-16 brings the category of the shortcut into focus", async () => {
    renderWith(demoRelay(), <PreferenceCenter focusCategory="social" />);
    await screen.findByTestId("relay-preference-matrix");
    await waitFor(() =>
      expect(document.activeElement?.textContent).toContain("Mentions and comments"),
    );
  });
});

describe("X-23 webhook portal", () => {
  it("WH-40 shows the address check's answer at the field", async () => {
    const relay = demoRelay();
    renderWith(relay, <WebhookPortal />);
    fireEvent.click(await screen.findByRole("button", { name: "Add endpoint" }));
    const form = screen.getByTestId("relay-endpoint-form");
    fireEvent.change(within(form).getByLabelText("Endpoint URL"), {
      target: { value: "https://10.0.0.5/hook" },
    });
    fireEvent.click(await within(form).findByRole("checkbox", { name: /order.created/ }));
    fireEvent.submit(form);
    expect((await within(form).findByTestId("relay-url-error")).textContent).toContain(
      "private address",
    );
    expect(within(form).getByLabelText("Endpoint URL").getAttribute("aria-invalid")).toBe("true");
  });

  it("WH-40 refuses an address that is not https before sending", async () => {
    const relay = demoRelay();
    renderWith(relay, <WebhookPortal />);
    fireEvent.click(await screen.findByRole("button", { name: "Add endpoint" }));
    const form = screen.getByTestId("relay-endpoint-form");
    fireEvent.change(within(form).getByLabelText("Endpoint URL"), {
      target: { value: "http://hooks.example.com" },
    });
    fireEvent.submit(form);
    expect((await within(form).findByTestId("relay-url-error")).textContent).toContain("https://");
    expect(
      relay.requests.some(
        (request) => request.method === "POST" && request.path === "/v1/portal/webhook_endpoints",
      ),
    ).toBe(false);
  });

  it("WH-46 creates an endpoint with event types from the tenant catalog", async () => {
    const relay = demoRelay();
    renderWith(relay, <WebhookPortal />);
    fireEvent.click(await screen.findByRole("button", { name: "Add endpoint" }));
    const form = screen.getByTestId("relay-endpoint-form");
    fireEvent.change(within(form).getByLabelText("Endpoint URL"), {
      target: { value: "https://new.customer.example/hook" },
    });
    fireEvent.click(await within(form).findByRole("checkbox", { name: /order.shipped/ }));
    fireEvent.submit(form);
    await waitFor(() => expect(screen.queryByTestId("relay-endpoint-form")).toBeNull());
    const created = relay.requests.find(
      (request) => request.method === "POST" && request.path === "/v1/portal/webhook_endpoints",
    );
    expect(created?.body).toEqual({
      url: "https://new.customer.example/hook",
      event_types: ["order.shipped"],
      signature_scheme: "v1a",
    });
  });

  it("WH-39 shows the disable reason and the endpoint health", async () => {
    renderWith(demoRelay(), <WebhookPortal />);
    expect((await screen.findByTestId("relay-disabled-reason")).textContent).toContain("five days");
    const first = (await screen.findAllByTestId("relay-endpoint"))[0] as HTMLElement;
    fireEvent.click(within(first).getByRole("button", { name: "Health" }));
    expect((await within(first).findByTestId("relay-endpoint-health")).textContent).toContain(
      "98.0%",
    );
  });

  it("WH-32 resends one failed delivery and shows its attempts", async () => {
    const relay = demoRelay();
    renderWith(relay, <WebhookPortal />);
    const messages = await screen.findAllByTestId("relay-message");
    const failed = messages.find((message) =>
      message.textContent?.includes("order.shipped"),
    ) as HTMLElement;
    fireEvent.click(within(failed).getByRole("button", { name: "Attempts" }));
    expect(await within(failed).findByText(/Attempt 1/)).toBeTruthy();
    fireEvent.click(within(failed).getByRole("button", { name: "Resend" }));
    await waitFor(() =>
      expect(screen.getByTestId("relay-portal-status").textContent).toContain("Resend started."),
    );
  });

  it("WH-31 resends the failed deliveries of a time range", async () => {
    const relay = demoRelay();
    renderWith(relay, <WebhookPortal />);
    const disabled = (await screen.findAllByTestId("relay-endpoint"))[1] as HTMLElement;
    const from = within(disabled).getByLabelText("From");
    fireEvent.change(from, { target: { value: "2026-11-01T00:00" } });
    await act(async () => {
      fireEvent.submit(from.closest("form") as HTMLFormElement);
    });
    await waitFor(() =>
      expect(screen.getByTestId("relay-portal-status").textContent).toContain(
        "1 deliveries queued again.",
      ),
    );
  });
});
