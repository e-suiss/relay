import { InboxClient, RelaySubscriberClient } from "@esuiss/relay/browser";
import { describe, expect, it } from "vitest";
import {
  commitMarkAllRead,
  pendingReadItems,
  pressMarkAllRead,
  withPendingRead,
} from "../src/inbox/mark-all-read.js";
import {
  allItems,
  badgeCount,
  badgeText,
  categoriesOf,
  snoozeTimes,
  visibleItems,
} from "../src/inbox/view.js";
import { isApprovalItem, senderTypeOf, waitpointOf } from "../src/seams.js";
import { createFakeRelay, fakeItem, fakeWaitpoint } from "../src/testing/index.js";

const now = Date.parse("2026-11-18T12:00:00Z");

function counters(unseen: number, unread: number) {
  return { unseen, unread, total: unread, version: 1 };
}

describe("IN-20 badge", () => {
  it("IN-20 caps the in-app badge at 99+ and hides zero", () => {
    expect(badgeText(0)).toBe("");
    expect(badgeText(7)).toBe("7");
    expect(badgeText(99)).toBe("99");
    expect(badgeText(100)).toBe("99+");
  });

  it("X-17 lowers the badge at once for items marked read in the undo window", () => {
    const items = [
      fakeItem("a"),
      fakeItem("b", { seen: true }),
      fakeItem("c", { read: true, seen: true }),
    ];
    expect(badgeCount(counters(1, 2), "unseen", items)).toBe(0);
    expect(badgeCount(counters(1, 2), "unread", items)).toBe(0);
    expect(badgeCount(null, "unseen")).toBe(0);
  });
});

describe("X-16 filters", () => {
  const items = [
    fakeItem("a", { category: "orders", tags: ["shipping"] }),
    fakeItem("b", { category: "social", read: true }),
    fakeItem("c", { category: "orders", archived: true }),
    fakeItem("d", { category: "orders", snoozed_until: "2026-11-19T09:00:00Z" }),
    fakeItem("e", { category: "orders", snoozed_until: "2026-11-17T09:00:00Z" }),
  ];

  it("X-16 shows the inbox tab without archived and snoozed items", () => {
    expect(visibleItems(items, allItems, now).map((item) => item.id)).toEqual(["a", "b", "e"]);
  });

  it("X-16 narrows by category, tag and unread", () => {
    expect(
      visibleItems(items, { category: "orders", tag: null, unreadOnly: false }, now).map(
        (item) => item.id,
      ),
    ).toEqual(["a", "e"]);
    expect(
      visibleItems(items, { category: null, tag: "shipping", unreadOnly: false }, now).map(
        (item) => item.id,
      ),
    ).toEqual(["a"]);
    expect(
      visibleItems(items, { category: null, tag: null, unreadOnly: true }, now).map(
        (item) => item.id,
      ),
    ).toEqual(["a", "e"]);
    expect(categoriesOf(items)).toEqual(["orders", "social"]);
  });

  it("X-16 offers an hour, tomorrow morning and next week as snooze times", () => {
    const times = snoozeTimes(new Date(2026, 10, 18, 12, 0));
    expect(Date.parse(times.hour) - new Date(2026, 10, 18, 12, 0).getTime()).toBe(3_600_000);
    expect(new Date(times.tomorrow).getDate()).toBe(19);
    expect(new Date(times.tomorrow).getHours()).toBe(9);
    expect(new Date(times.week).getDay()).toBe(1);
  });
});

describe("C-24 and IN-6 item seams", () => {
  it("C-24 reads the sender type when the item carries it", () => {
    expect(senderTypeOf(fakeItem("a", { sender_type: "agent" }))).toBe("agent");
    expect(senderTypeOf(fakeItem("a"))).toBeNull();
    expect(senderTypeOf({ ...fakeItem("a"), sender_type: undefined })).toBeNull();
  });

  it("AG-35 reads the typed waitpoint and gives null without one", () => {
    expect(waitpointOf(fakeItem("a"))).toBeNull();
    expect(waitpointOf({ ...fakeItem("a"), waitpoint: undefined })).toBeNull();
    const waitpoint = waitpointOf(
      fakeItem("a", {
        waitpoint: fakeWaitpoint("wp_1", {
          status: "processing",
          subject_digest: "d",
          options: [{ label: "Yes", value: "yes" }],
        }),
      }),
    );
    expect(waitpoint?.status).toBe("processing");
    expect(waitpoint?.options).toEqual([{ label: "Yes", value: "yes" }]);
  });

  it("IN-6 knows an approval item by its flag or its approval waitpoint", () => {
    expect(isApprovalItem(fakeItem("a", { approval: true }))).toBe(true);
    expect(
      isApprovalItem(fakeItem("a", { waitpoint: fakeWaitpoint("wp_1", { kind: "approval" }) })),
    ).toBe(true);
    expect(isApprovalItem(fakeItem("a", { waitpoint: fakeWaitpoint("wp_1") }))).toBe(false);
    expect(isApprovalItem(fakeItem("a"))).toBe(false);
  });
});

function inboxWith(relay: ReturnType<typeof createFakeRelay>) {
  const client = new RelaySubscriberClient({
    baseUrl: "https://relay.example.com",
    token: relay.token,
    fetch: relay.fetch,
  });
  const inbox = new InboxClient({
    client,
    realtime: false,
    storage: null,
    visibility: null,
    online: null,
  });
  return { client, inbox };
}

describe("X-17 mark all as read", () => {
  it("X-17 captures only the unread items of the filtered view at the press", () => {
    const items = [
      fakeItem("a", { category: "orders" }),
      fakeItem("b", { category: "social" }),
      fakeItem("c", { category: "orders", read: true }),
    ];
    const pending = pressMarkAllRead(
      items,
      { category: "orders", tag: null, unreadOnly: false },
      now,
    );
    expect([...pending.itemIds]).toEqual(["a"]);
    expect(pending.pressedAt).toBe(now);
    expect(withPendingRead(items, pending).find((item) => item.id === "a")?.read).toBe(true);
    expect(pendingReadItems(items, pending).map((item) => item.id)).toEqual(["a"]);
  });

  it("X-17 marks one category read in one request and archives nothing", async () => {
    const relay = createFakeRelay({
      items: [fakeItem("a", { category: "orders" }), fakeItem("b", { category: "social" })],
    });
    const { client, inbox } = inboxWith(relay);
    await inbox.start();
    const pending = pressMarkAllRead(
      inbox.snapshot().items,
      { category: "orders", tag: null, unreadOnly: false },
      Date.now(),
    );
    await commitMarkAllRead(inbox, client, pending);
    const readAll = relay.requests.filter(
      (request) => request.path === "/v1/subscriber/inbox/read_all",
    );
    expect(readAll).toHaveLength(1);
    expect(readAll[0]?.body).toEqual({ category: "orders" });
    expect(relay.state.items.find((item) => item.id === "a")?.read).toBe(true);
    expect(relay.state.items.find((item) => item.id === "b")?.read).toBe(false);
    expect(relay.state.items.some((item) => item.archived)).toBe(false);
    inbox.stop();
  });

  it("X-17 an item that arrived after the press stays unread", async () => {
    const relay = createFakeRelay({ items: [fakeItem("a")] });
    const { client, inbox } = inboxWith(relay);
    await inbox.start();
    const pending = pressMarkAllRead(inbox.snapshot().items, allItems, Date.now());
    relay.state.items = [fakeItem("late"), ...relay.state.items];
    await inbox.deltaSync();
    await commitMarkAllRead(inbox, client, pending);
    await new Promise((resolve) => setTimeout(resolve, 0));
    await inbox.deltaSync();
    expect(relay.state.items.find((item) => item.id === "a")?.read).toBe(true);
    expect(relay.state.items.find((item) => item.id === "late")?.read).toBe(false);
    inbox.stop();
  });

  it("X-17 a tag view goes through a bulk read", async () => {
    const relay = createFakeRelay({
      items: [fakeItem("a", { tags: ["shipping"] }), fakeItem("b")],
    });
    const { client, inbox } = inboxWith(relay);
    await inbox.start();
    const pending = pressMarkAllRead(
      inbox.snapshot().items,
      { category: null, tag: "shipping", unreadOnly: false },
      Date.now(),
    );
    await commitMarkAllRead(inbox, client, pending, { wait: async () => undefined });
    const bulk = relay.requests.find((request) => request.path === "/v1/subscriber/inbox/bulk");
    expect(bulk?.body).toEqual({ action: "read", filter: { status: "inbox", tag: "shipping" } });
    expect(relay.state.items.find((item) => item.id === "b")?.read).toBe(false);
    inbox.stop();
  });
});
