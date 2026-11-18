import {
  createFakeRelay,
  demoRelay,
  fakeConsent,
  fakeItem,
  fakeToken,
  fakeWaitpoint,
} from "@esuiss/relay-react/testing";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import {
  configureRelay,
  defineRelayElements,
  flushDisplayedNotifications,
  relayElementTags,
  reportDisplayedNotification,
  tokenFromUrl,
  type RelayElementsConfig,
} from "../src/index.js";

beforeAll(() => {
  defineRelayElements();
});

afterEach(() => {
  document.body.innerHTML = "";
});

async function until<T>(read: () => T | null | undefined, timeoutMs = 3000): Promise<T> {
  const start = Date.now();
  for (;;) {
    const value = read();
    if (value !== null && value !== undefined && value !== false) return value;
    if (Date.now() - start > timeoutMs) throw new Error("Timed out waiting.");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

function configFor(
  relay: ReturnType<typeof createFakeRelay>,
  extra: Partial<RelayElementsConfig> = {},
): RelayElementsConfig {
  return {
    baseUrl: "https://relay.example.com",
    token: relay.token,
    portalToken: relay.portalToken,
    fetch: relay.fetch,
    realtime: false,
    undoWindowMs: 50,
    locale: "en",
    colorScheme: "light",
    ...extra,
  };
}

function mount(
  tag: string,
  config: RelayElementsConfig | null,
  attributes: Record<string, string> = {},
): HTMLElement {
  const element = document.createElement(tag) as HTMLElement & {
    config: RelayElementsConfig | null;
  };
  for (const [name, value] of Object.entries(attributes)) element.setAttribute(name, value);
  if (config !== null) element.config = config;
  document.body.append(element);
  return element;
}

describe("X-32 web components", () => {
  it("X-32 defines every element once", () => {
    expect(relayElementTags).toEqual([
      "relay-bell",
      "relay-inbox",
      "relay-inbox-popover",
      "relay-toaster",
      "relay-preference-center",
      "relay-webhook-portal",
    ]);
    for (const tag of relayElementTags) expect(customElements.get(tag)).toBeDefined();
    expect(() => defineRelayElements()).not.toThrow();
  });

  it("X-32 renders the inbox in its shadow root", async () => {
    const relay = createFakeRelay({ items: [fakeItem("inb_1", { title: "Hello" })] });
    const element = mount("relay-inbox", configFor(relay));
    const item = await until(() =>
      element.shadowRoot?.querySelector("[data-testid=relay-inbox-item]"),
    );
    expect(item.textContent).toContain("Hello");
    expect(document.querySelector("[data-testid=relay-inbox-item]")).toBeNull();
  });

  it("X-32 themes through CSS custom properties that a page can set", async () => {
    const relay = createFakeRelay({ items: [fakeItem("inb_1")] });
    const element = mount("relay-inbox", configFor(relay, { theme: { accent: "#0b5c3b" } }));
    const root = await until(() => element.shadowRoot?.querySelector<HTMLElement>(".relay-root"));
    expect(root.style.getPropertyValue("--relay-default-color-accent")).toBe("#0b5c3b");
    const css = element.shadowRoot?.querySelector(".relay-root style")?.textContent ?? "";
    expect(css).toContain("var(--relay-color-accent, var(--relay-default-color-accent))");
  });

  it("X-32 follows the locale attribute", async () => {
    const relay = createFakeRelay({ items: [fakeItem("inb_1")] });
    const element = mount("relay-inbox", configFor(relay), { locale: "tr" });
    await until(() => element.shadowRoot?.querySelector("[data-testid=relay-delete]"));
    expect(element.shadowRoot?.querySelector("[data-testid=relay-delete]")?.textContent).toBe(
      "Sil",
    );
    element.setAttribute("locale", "en");
    await until(
      () =>
        element.shadowRoot?.querySelector("[data-testid=relay-delete]")?.textContent === "Delete",
    );
  });

  it("X-16 the category shortcut is a DOM event the host handles", async () => {
    const relay = createFakeRelay({ items: [fakeItem("inb_1", { category: "orders" })] });
    const element = mount("relay-inbox", configFor(relay));
    const listener = vi.fn();
    document.addEventListener("relay-open-preferences", listener);
    const shortcut = await until(() =>
      element.shadowRoot?.querySelector<HTMLElement>("[data-testid=relay-category-shortcut]"),
    );
    shortcut.click();
    expect(listener).toHaveBeenCalledTimes(1);
    expect((listener.mock.calls[0]?.[0] as CustomEvent).detail).toEqual({ category: "orders" });
    document.removeEventListener("relay-open-preferences", listener);
  });

  it("X-32 elements that share a configuration share one inbox", async () => {
    const relay = createFakeRelay({ items: [fakeItem("inb_1")] });
    const config = configFor(relay);
    const bell = mount("relay-bell", config, { "badge-source": "unread" });
    const inbox = mount("relay-inbox", config);
    await until(() => inbox.shadowRoot?.querySelector("[data-testid=relay-inbox-item]"));
    await until(
      () => bell.shadowRoot?.querySelector("[data-testid=relay-badge]")?.textContent === "1",
    );
    expect(
      relay.requests.filter((request) => request.path === "/v1/subscriber/inbox/items"),
    ).toHaveLength(1);
  });

  it("X-32 uses the global configuration", async () => {
    const relay = demoRelay();
    configureRelay(configFor(relay));
    const element = mount("relay-preference-center", null);
    await until(() => element.shadowRoot?.querySelector("[data-testid=relay-preference-matrix]"));
    expect(element.shadowRoot?.textContent).toContain("On (locked)");
  });

  it("X-44 the preference center reads consents from the subscriber API, read-only", async () => {
    const relay = demoRelay();
    relay.state.consents = [fakeConsent("email", "active")];
    const element = mount(
      "relay-preference-center",
      configFor(relay, { links: { accessConsentUrl: "https://access.example.com/consents" } }),
    );
    const section = await until(() =>
      element.shadowRoot?.querySelector<HTMLElement>("[data-testid=relay-consents]"),
    );
    await until(() => section.textContent?.includes("E-mail: Given"));
    expect(section.querySelectorAll("[role=switch], button")).toHaveLength(0);
    expect(section.querySelector("a")?.getAttribute("href")).toBe(
      "https://access.example.com/consents",
    );
    expect(
      relay.requests.some(
        (request) => request.path === "/v1/subscriber/consents" && request.method === "GET",
      ),
    ).toBe(true);
  });

  it("X-44 without an Access link the consent section links nowhere", async () => {
    const relay = demoRelay();
    const element = mount("relay-preference-center", configFor(relay));
    const section = await until(() =>
      element.shadowRoot?.querySelector<HTMLElement>("[data-testid=relay-consents]"),
    );
    await until(() => section.textContent?.includes("E-mail: Not given"));
    expect(section.querySelector("a")).toBeNull();
  });

  it("C-24 AG-35 IN-6 the inbox shows the agent label, waitpoint states and approval link", async () => {
    const relay = createFakeRelay({
      items: [
        fakeItem("inb_1", {
          sender_type: "agent",
          waitpoint: fakeWaitpoint("wp_1", {
            subject_digest: "d1",
            options: [{ label: "Yes", value: "yes" }],
          }),
        }),
        fakeItem("inb_2", {
          waitpoint: fakeWaitpoint("wp_2", { status: "not_awaited" }),
        }),
        fakeItem("inb_3", {
          approval: true,
          waitpoint: fakeWaitpoint("wp_3", {
            kind: "approval",
            approval_url: "https://access.example.com/approvals/3",
          }),
        }),
      ],
    });
    const element = mount("relay-inbox", configFor(relay));
    const root = await until(() => element.shadowRoot);
    const within = (id: string, selector: string) =>
      root.querySelector<HTMLElement>(`[data-item-id="${id}"] ${selector}`);
    await until(() => within("inb_1", "[data-testid=relay-waitpoint]"));
    expect(within("inb_1", "[data-testid=relay-agent-mark]")?.textContent).toContain(
      "Sent by an AI agent",
    );
    expect(within("inb_2", "[data-testid=relay-agent-mark]")).toBeNull();
    expect(within("inb_2", "[data-testid=relay-waitpoint]")?.textContent).toContain(
      "No longer expecting a response",
    );
    expect(within("inb_3", "[data-testid=relay-approval-link]")?.getAttribute("href")).toBe(
      "https://access.example.com/approvals/3",
    );
    expect(within("inb_3", "[data-testid=relay-waitpoint]")).toBeNull();
    const yes = [...root.querySelectorAll<HTMLButtonElement>("button")].find(
      (button) => button.textContent === "Yes",
    );
    yes?.click();
    await until(() =>
      within("inb_1", "[data-testid=relay-waitpoint]")?.textContent?.includes("Answered by you"),
    );
    const response = relay.requests.find(
      (request) => request.path === "/v1/subscriber/waitpoints/wp_1/response",
    );
    expect(response?.body).toEqual({ response: "yes", subject_digest: "d1" });
  });

  it("X-23 renders the webhook portal with the portal token", async () => {
    const relay = demoRelay();
    const element = mount("relay-webhook-portal", configFor(relay));
    await until(() => element.shadowRoot?.querySelector("[data-testid=relay-endpoint]"));
    expect(
      relay.requests.every((request) => request.authorization === `Bearer ${relay.portalToken()}`),
    ).toBe(true);
  });

  it("X-32 refuses a token that is not narrow", async () => {
    const relay = createFakeRelay({ items: [fakeItem("inb_1")] });
    const element = mount("relay-inbox", configFor(relay, { token: () => fakeToken("at+jwt") }));
    await until(() => element.shadowRoot?.querySelector("[role=alert]"));
    expect(relay.requests).toHaveLength(0);
  });

  it("X-32 reads a token from the application's endpoint", async () => {
    const token = fakeToken("relay-subscriber+jwt");
    const fetcher = vi.fn(
      async () => new Response(JSON.stringify({ access_token: token }), { status: 200 }),
    );
    await expect(tokenFromUrl("/relay/token", fetcher as unknown as typeof fetch)()).resolves.toBe(
      token,
    );
    const plain = vi.fn(async () => new Response(token, { status: 200 }));
    await expect(tokenFromUrl("/relay/token", plain as unknown as typeof fetch)()).resolves.toBe(
      token,
    );
    const failing = vi.fn(async () => new Response("no", { status: 401 }));
    await expect(
      tokenFromUrl("/relay/token", failing as unknown as typeof fetch)(),
    ).rejects.toThrow("401");
  });

  it("OP-54 reports digests of rendered and host-displayed notifications when turned on", async () => {
    const relay = createFakeRelay({ items: [fakeItem("inb_1")] });
    const config = configFor(relay, { reportDisplayedNotifications: true });
    const element = mount("relay-inbox", config);
    await until(() => element.shadowRoot?.querySelector("[data-testid=relay-inbox-item]"));
    reportDisplayedNotification("ntf_1", config);
    for (let attempt = 0; relay.state.displayed.length < 2 && attempt < 100; attempt++) {
      await flushDisplayedNotifications(config);
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    expect(relay.state.displayed).toHaveLength(2);
    expect(relay.state.displayed.every((entry) => /^[0-9a-f]{64}$/.test(entry.digest))).toBe(true);
    const sent = JSON.stringify(
      relay.requests.filter((request) => request.path === "/v1/subscriber/displayed_notifications"),
    );
    expect(sent).not.toContain("inb_1");
    expect(sent).not.toContain("ntf_1");
  });

  it("OP-54 reports nothing by default", async () => {
    const relay = createFakeRelay({ items: [fakeItem("inb_1")] });
    const config = configFor(relay);
    const element = mount("relay-inbox", config);
    await until(() => element.shadowRoot?.querySelector("[data-testid=relay-inbox-item]"));
    reportDisplayedNotification("ntf_1", config);
    await flushDisplayedNotifications(config);
    expect(relay.state.displayed).toHaveLength(0);
  });
});
