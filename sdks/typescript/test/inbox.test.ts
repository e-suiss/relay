import { describe, expect, it } from "vitest";
import {
  InboxClient,
  applyIntent,
  compactQueue,
  stillSendable,
  type InboxItem,
  type InboxNotice,
  type QueuedIntent,
  type StorageLike,
} from "../src/browser/inbox.js";
import type { WebSocketLike } from "../src/browser/realtime.js";
import { RelaySubscriberClient } from "../src/browser/subscriber.js";
import { noSleep } from "./helpers.js";

function item(id: string, version: number, fields: Partial<InboxItem> = {}): InboxItem {
  return {
    id,
    state_version: version,
    seen: false,
    read: false,
    archived: false,
    hidden: false,
    expired: false,
    snoozed_until: null,
    ...fields,
  };
}

function counters(unseen: number, unread: number, total: number, version: number) {
  return { object: "inbox_counters", unseen, unread, total, version };
}

interface Request {
  readonly method: string;
  readonly path: string;
  readonly body: Record<string, unknown> | null;
  readonly key: string | null;
}

type Route = (
  request: Request,
) => { status?: number; body: unknown } | Promise<{ status?: number; body: unknown }>;

function subscriber(route: Route, requests: Request[]): RelaySubscriberClient {
  return new RelaySubscriberClient({
    baseUrl: "https://relay.example.com",
    token: () => "subscriber-token",
    sleep: noSleep,
    fetch: async (input, init) => {
      const url = new URL(input);
      const request: Request = {
        method: init?.method ?? "GET",
        path: url.pathname + url.search,
        body:
          typeof init?.body === "string"
            ? (JSON.parse(init.body) as Record<string, unknown>)
            : null,
        key: new Headers(init?.headers).get("idempotency-key"),
      };
      requests.push(request);
      const answer = await route(request);
      const status = answer.status ?? 200;
      return new Response(JSON.stringify(answer.body), {
        status,
        headers: {
          "content-type": status >= 400 ? "application/problem+json" : "application/json",
        },
      });
    },
  });
}

function page(items: InboxItem[], version: number) {
  const unseen = items.filter((entry) => !entry.seen).length;
  const unread = items.filter((entry) => !entry.read).length;
  return {
    object: "list",
    data: items,
    has_more: false,
    next_cursor: null,
    previous_cursor: null,
    counters: counters(unseen, unread, items.length, version),
    cursor: "s1",
  };
}

class MemoryStorage implements StorageLike {
  readonly values = new Map<string, string>();
  getItem(key: string): string | null {
    return this.values.get(key) ?? null;
  }
  setItem(key: string, value: string): void {
    this.values.set(key, value);
  }
}

const settle = async (): Promise<void> => {
  for (let index = 0; index < 20; index++) await new Promise((resolve) => setTimeout(resolve, 0));
};

const intents = (requests: Request[]) =>
  requests.filter((request) => request.path.includes("/intents"));

describe("IN-12 IN-13 offline queue", () => {
  it("IN-13: the queue keeps one intent per item, newest wins, in client_seq order", () => {
    const queued = (op: QueuedIntent["op"], id: string, seq: number): QueuedIntent => ({
      op,
      item_id: id,
      client_seq: seq,
      key: `key-${seq}`,
      offline: true,
    });
    expect(
      compactQueue([queued("read", "a", 1), queued("seen", "b", 2), queued("archive", "a", 3)]),
    ).toEqual([queued("seen", "b", 2), queued("archive", "a", 3)]);
  });

  it("IN-13: a reverse intent based on an older state is dropped, a monotone one is still sent", () => {
    const base = { item_id: "a", client_seq: 1, key: "k", offline: true, base_state_version: 2 };
    expect(stillSendable({ ...base, op: "unread" }, 3)).toBe(false);
    expect(stillSendable({ ...base, op: "unread" }, 2)).toBe(true);
    expect(stillSendable({ ...base, op: "read" }, 5)).toBe(true);
  });

  it("IN-9: read also marks seen; hide is terminal for the list", () => {
    expect(applyIntent(item("a", 1), "read")).toMatchObject({ read: true, seen: true });
    expect(applyIntent(item("a", 1), "hide")).toMatchObject({ hidden: true });
  });

  it("IN-13: offline intents wait, compacted per item, and go out with client_seq when back online", async () => {
    const requests: Request[] = [];
    let online = false;
    const listeners: (() => void)[] = [];
    const storage = new MemoryStorage();
    const client = subscriber((request) => {
      if (request.path.startsWith("/v1/subscriber/inbox/counters"))
        return { body: counters(2, 2, 2, 1) };
      if (request.path.startsWith("/v1/subscriber/inbox/items?"))
        return { body: page([item("a", 1), item("b", 1)], 1) };
      const id = request.path.split("/")[5] ?? "";
      return {
        body: {
          object: "inbox_intent_result",
          item_id: id,
          op: request.body?.op,
          client_seq: request.body?.client_seq,
          result: "applied",
          state: item(id, 2, { seen: true, read: true }),
          counters: counters(0, 0, 2, 5),
        },
      };
    }, requests);
    const inbox = new InboxClient({
      client,
      realtime: false,
      storage,
      visibility: null,
      isOnline: () => online,
      online: {
        addEventListener: (_type, listener) => listeners.push(listener),
        removeEventListener: () => undefined,
      },
    });
    await inbox.start();
    inbox.markSeen("a");
    inbox.markRead("a");
    inbox.markRead("b");
    await settle();
    expect(intents(requests)).toHaveLength(0);
    expect(inbox.snapshot().pending).toBe(2);
    expect(inbox.snapshot().counters).toMatchObject({ unseen: 0, unread: 0 });
    expect(JSON.parse(storage.getItem("esuiss-relay-inbox-queue") ?? "{}").queue).toHaveLength(2);
    online = true;
    for (const listener of listeners) listener();
    await settle();
    const sent = intents(requests);
    expect(
      sent.map((request) => [request.path, request.body?.op, request.body?.client_seq]),
    ).toEqual([
      ["/v1/subscriber/inbox/items/a/intents", "read", 2],
      ["/v1/subscriber/inbox/items/b/intents", "read", 3],
    ]);
    expect(sent.every((request) => request.key !== null)).toBe(true);
    expect(inbox.snapshot().pending).toBe(0);
    expect(inbox.snapshot().counters).toEqual({ unseen: 0, unread: 0, total: 2, version: 5 });
    inbox.stop();
  });

  it("IN-12: a 409 is accepted silently; only a reverse change made on screen is told", async () => {
    const requests: Request[] = [];
    const current = item("a", 4, { seen: true, read: true });
    const client = subscriber((request) => {
      if (request.path.startsWith("/v1/subscriber/inbox/counters"))
        return { body: counters(0, 0, 1, 1) };
      if (request.path.startsWith("/v1/subscriber/inbox/items?")) {
        return { body: page([item("a", 3, { seen: true, read: true })], 1) };
      }
      return {
        status: 409,
        body: {
          type: "https://relay.example.com/v1/errors/inbox_item_conflict",
          title: "Inbox item changed",
          status: 409,
          code: "inbox_item_conflict",
          retryable: false,
          current,
        },
      };
    }, requests);
    const notices: InboxNotice[] = [];
    const inbox = new InboxClient({
      client,
      realtime: false,
      storage: null,
      visibility: null,
      online: null,
      isOnline: () => true,
    });
    inbox.onNotice((notice) => notices.push(notice));
    await inbox.start();
    inbox.markUnread("a");
    await settle();
    expect(intents(requests)[0]?.body).toMatchObject({ op: "unread", base_state_version: 3 });
    expect(inbox.snapshot().items[0]).toMatchObject({ id: "a", read: true, state_version: 4 });
    expect(notices).toEqual([{ type: "updated_elsewhere", itemId: "a", op: "unread" }]);
    inbox.stop();
  });
});

describe("IN-15 undo buffer", () => {
  it("IN-15: an undoable archive waits in the client buffer and undo never reaches the server", async () => {
    const requests: Request[] = [];
    const timers: (() => void)[] = [];
    const client = subscriber((request) => {
      if (request.path.startsWith("/v1/subscriber/inbox/counters"))
        return { body: counters(1, 1, 1, 1) };
      if (request.path.startsWith("/v1/subscriber/inbox/items?"))
        return { body: page([item("a", 1)], 1) };
      return {
        body: {
          object: "inbox_intent_result",
          item_id: "a",
          op: "archive",
          client_seq: 2,
          result: "applied",
          state: item("a", 2, { archived: true }),
          counters: counters(0, 0, 0, 2),
        },
      };
    }, requests);
    const inbox = new InboxClient({
      client,
      realtime: false,
      storage: null,
      visibility: null,
      online: null,
      isOnline: () => true,
      setTimeout: (callback) => {
        timers.push(callback);
        return timers.length;
      },
      clearTimeout: () => undefined,
    });
    await inbox.start();
    const first = inbox.archive("a", { undoable: true });
    expect(inbox.snapshot().items[0]).toMatchObject({ archived: true });
    expect(inbox.snapshot().counters).toMatchObject({ total: 0 });
    expect(first.undo()).toBe(true);
    expect(inbox.snapshot().items[0]).toMatchObject({ archived: false });
    expect(inbox.snapshot().counters).toMatchObject({ total: 1, unseen: 1 });
    await settle();
    expect(intents(requests)).toHaveLength(0);
    const second = inbox.archive("a", { undoable: true });
    timers.at(-1)?.();
    await settle();
    expect(second.undo()).toBe(false);
    expect(intents(requests)).toHaveLength(1);
    expect(inbox.snapshot().counters).toEqual({ unseen: 0, unread: 0, total: 0, version: 2 });
    inbox.stop();
  });
});

describe("IN-21 foreground counter sync", () => {
  it("IN-21: coming to the foreground asks for the counters and reports a mismatch with the list", async () => {
    const requests: Request[] = [];
    let visibility = "hidden";
    const listeners: (() => void)[] = [];
    let countersRead = 0;
    const client = subscriber((request) => {
      if (request.path.startsWith("/v1/subscriber/inbox/counters/inconsistency")) {
        return {
          body: {
            object: "inbox_reconciliation",
            result: "repaired",
            counters: counters(1, 1, 1, 9),
          },
        };
      }
      if (request.path.startsWith("/v1/subscriber/inbox/counters")) {
        countersRead++;
        return { body: countersRead === 1 ? counters(1, 1, 1, 1) : counters(4, 4, 4, 8) };
      }
      return { body: page([item("a", 1)], 1) };
    }, requests);
    const inbox = new InboxClient({
      client,
      realtime: false,
      storage: null,
      online: null,
      isOnline: () => true,
      visibility: {
        get visibilityState() {
          return visibility;
        },
        addEventListener: (_type, listener) => listeners.push(listener),
        removeEventListener: () => undefined,
      },
    });
    await inbox.start();
    expect(inbox.snapshot().counters).toMatchObject({ unseen: 1, version: 1 });
    visibility = "visible";
    for (const listener of listeners) listener();
    await settle();
    expect(countersRead).toBe(2);
    expect(
      requests.some((request) => request.path === "/v1/subscriber/inbox/counters/inconsistency"),
    ).toBe(true);
    expect(inbox.snapshot().counters).toEqual({ unseen: 1, unread: 1, total: 1, version: 9 });
    inbox.stop();
  });
});

describe("IN-28 stream before list", () => {
  it("IN-28: events that arrive while the list loads are applied after it, newer ones only", async () => {
    const requests: Request[] = [];
    let releaseList = null as (() => void) | null;
    const listed = new Promise<void>((resolve) => {
      releaseList = resolve;
    });
    const sockets: { socket: WebSocketLike & { open(): void; push(message: unknown[]): void } }[] =
      [];
    const client = subscriber(async (request) => {
      if (request.path.startsWith("/v1/subscriber/inbox/counters"))
        return { body: counters(2, 2, 2, 1) };
      await listed;
      return { body: page([item("a", 1), item("b", 3)], 1) };
    }, requests);
    const inbox = new InboxClient({
      client,
      tabs: false,
      storage: null,
      visibility: null,
      online: null,
      isOnline: () => true,
      realtime: {
        transports: ["websocket"],
        env: {
          setTimeout: () => 0,
          clearTimeout: () => undefined,
          random: () => 0.5,
          webSocket: () => {
            const socket = {
              readyState: 0,
              onopen: null as ((event: unknown) => void) | null,
              onmessage: null as ((event: { readonly data: unknown }) => void) | null,
              onclose: null as
                ((event: { readonly code: number; readonly reason: string }) => void) | null,
              onerror: null as ((event: unknown) => void) | null,
              send: () => undefined,
              close: () => undefined,
              open() {
                this.onopen?.({});
              },
              push(message: unknown[]) {
                this.onmessage?.({ data: JSON.stringify(message) });
              },
            };
            sockets.push({ socket });
            return socket;
          },
        },
      },
    });
    const starting = inbox.start();
    await settle();
    const socket = sockets[0]?.socket;
    if (socket === undefined) throw new Error("the stream was not opened before the list");
    expect(requests.some((request) => request.path.startsWith("/v1/subscriber/inbox/items"))).toBe(
      true,
    );
    socket.open();
    socket.push(["1", "1", "inbox", "phx_reply", { status: "ok", response: {} }]);
    const envelopeCounters = { unseen: 1, unread: 2, total: 2, version: 2 };
    socket.push([
      "1",
      null,
      "inbox",
      "inbox.item_updated",
      {
        t: "inbox.item_updated",
        v: 1,
        ts: "2026-11-18T10:00:00Z",
        d: { item_id: "a", state_version: 2, changes: { seen: true } },
        counters: envelopeCounters,
        id: "s2",
      },
    ]);
    socket.push([
      "1",
      null,
      "inbox",
      "inbox.item_updated",
      {
        t: "inbox.item_updated",
        v: 1,
        ts: "2026-11-18T10:00:00Z",
        d: { item_id: "b", state_version: 2, changes: { archived: true } },
        counters: envelopeCounters,
        id: "s3",
      },
    ]);
    releaseList?.();
    await starting;
    await settle();
    const items = inbox.snapshot().items;
    expect(items.find((entry) => entry.id === "a")).toMatchObject({ seen: true, state_version: 2 });
    expect(items.find((entry) => entry.id === "b")).toMatchObject({
      archived: false,
      state_version: 3,
    });
    expect(inbox.snapshot().counters).toEqual(envelopeCounters);
    inbox.stop();
  });
});
