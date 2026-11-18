import { describe, expect, it } from "vitest";
import {
  RealtimeConnection,
  RealtimeError,
  reconnectDelay,
  type RealtimeEnvelope,
  type RealtimeStatus,
  type WebSocketLike,
} from "../src/browser/realtime.js";
import { SubscriberTokenSource } from "../src/browser/token.js";
import { readSse } from "../src/core/sse.js";

class FakeSocket implements WebSocketLike {
  readyState = 0;
  onopen: ((event: unknown) => void) | null = null;
  onmessage: ((event: { readonly data: unknown }) => void) | null = null;
  onclose: ((event: { readonly code: number; readonly reason: string }) => void) | null = null;
  onerror: ((event: unknown) => void) | null = null;
  readonly sent: unknown[][] = [];
  closed = false;

  constructor(
    readonly url: string,
    readonly protocols: string[],
  ) {}

  send(data: string): void {
    this.sent.push(JSON.parse(data) as unknown[]);
  }

  close(): void {
    this.closed = true;
  }

  open(): void {
    this.readyState = 1;
    this.onopen?.({});
  }

  receive(message: unknown[]): void {
    this.onmessage?.({ data: JSON.stringify(message) });
  }

  drop(code: number, reason = ""): void {
    this.readyState = 3;
    this.onclose?.({ code, reason });
  }
}

const counters = { unseen: 1, unread: 1, total: 2, version: 7 };

function envelope(id: string, version = 7): RealtimeEnvelope {
  return {
    t: "inbox.counters_changed",
    v: 1,
    ts: "2026-11-18T10:00:00Z",
    d: { ...counters, version },
    counters: { ...counters, version },
    id,
  };
}

function sseResponse(text: string): Response {
  const bytes = new TextEncoder().encode(text);
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(bytes.slice(0, 10));
      controller.enqueue(bytes.slice(10));
      controller.close();
    },
  });
  return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
}

const settle = async (): Promise<void> => {
  for (let index = 0; index < 10; index++) await new Promise((resolve) => setTimeout(resolve, 0));
};

interface Harness {
  readonly connection: RealtimeConnection;
  readonly sockets: FakeSocket[];
  readonly requests: { url: URL; headers: Headers }[];
  readonly envelopes: RealtimeEnvelope[];
  readonly statuses: RealtimeStatus[];
  readonly errors: RealtimeError[];
  readonly timers: { callback: () => void; ms: number }[];
}

function harness(options: {
  responses?: Response[];
  transports?: ("websocket" | "sse" | "poll")[];
  cursor?: string;
}): Harness {
  const sockets: FakeSocket[] = [];
  const requests: { url: URL; headers: Headers }[] = [];
  const envelopes: RealtimeEnvelope[] = [];
  const statuses: RealtimeStatus[] = [];
  const errors: RealtimeError[] = [];
  const timers: { callback: () => void; ms: number }[] = [];
  const responses = options.responses ?? [];
  const connection = new RealtimeConnection({
    baseUrl: "https://relay.example.com",
    tokens: new SubscriberTokenSource(() => "subscriber-token"),
    deviceId: "dev_1",
    ...(options.transports === undefined ? {} : { transports: options.transports }),
    ...(options.cursor === undefined ? {} : { cursor: options.cursor }),
    onEnvelope: (item) => envelopes.push(item),
    onStatus: (status) => statuses.push(status),
    onError: (error) => errors.push(error),
    env: {
      webSocket: (url, protocols) => {
        const socket = new FakeSocket(url, protocols);
        sockets.push(socket);
        return socket;
      },
      fetch: async (input, init) => {
        requests.push({ url: new URL(input), headers: new Headers(init?.headers) });
        const next = responses.shift();
        if (next === undefined) return new Promise<Response>(() => undefined);
        return next;
      },
      setTimeout: (callback, ms) => {
        if (ms < 30_000) timers.push({ callback, ms });
        return timers.length;
      },
      clearTimeout: () => undefined,
      random: () => 0.5,
    },
  });
  return { connection, sockets, requests, envelopes, statuses, errors, timers };
}

describe("IN-23 transports", () => {
  it("IN-23: the WebSocket joins the inbox topic with the subscriber token in the subprotocol", async () => {
    const h = harness({ cursor: "c0" });
    h.connection.start();
    await settle();
    const socket = h.sockets[0];
    if (socket === undefined) throw new Error("no socket");
    expect(socket.url).toBe(
      "wss://relay.example.com/v1/realtime/websocket?vsn=2.0.0&device_id=dev_1",
    );
    expect(socket.protocols[0]).toBe("phoenix");
    expect(socket.protocols[1]).toBe(
      `base64url.bearer.phx.${btoa("subscriber-token").replace(/=+$/, "")}`,
    );
    socket.open();
    expect(socket.sent[0]).toEqual(["1", "1", "inbox", "phx_join", { cursor: "c0" }]);
    socket.receive(["1", "1", "inbox", "phx_reply", { status: "ok", response: {} }]);
    expect(h.statuses.at(-1)).toMatchObject({ state: "open", transport: "websocket" });
    socket.receive(["1", null, "inbox", "inbox.counters_changed", envelope("c1")]);
    expect(h.envelopes.map((item) => item.id)).toEqual(["c1"]);
    expect(h.connection.cursor).toBe("c1");
    h.connection.stop();
    expect(socket.closed).toBe(true);
  });

  it("IN-23: a WebSocket that never opens hands over to SSE, which resumes with Last-Event-ID", async () => {
    const h = harness({
      cursor: "c0",
      responses: [
        sseResponse(
          `: keep-alive\n\nid: c1\nevent: inbox.counters_changed\ndata: ${JSON.stringify(envelope("c1"))}\n\n`,
        ),
      ],
    });
    h.connection.start();
    await settle();
    h.sockets[0]?.drop(1006);
    await settle();
    expect(h.requests[0]?.url.pathname).toBe("/v1/realtime/events");
    expect(h.requests[0]?.url.searchParams.get("device_id")).toBe("dev_1");
    expect(h.requests[0]?.headers.get("authorization")).toBe("Bearer subscriber-token");
    expect(h.requests[0]?.headers.get("last-event-id")).toBe("c0");
    expect(h.envelopes.map((item) => item.id)).toEqual(["c1"]);
    expect(h.connection.transport).toBe("sse");
    h.connection.stop();
  });

  it("IN-23: long-poll is the last resort and continues from the cursor it was given", async () => {
    const h = harness({
      transports: ["poll"],
      responses: [
        new Response(JSON.stringify({ events: [envelope("c1")], cursor: "c1" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
      ],
    });
    h.connection.start();
    await settle();
    expect(h.requests[0]?.url.pathname).toBe("/v1/realtime/poll");
    expect(h.requests[0]?.url.searchParams.get("cursor")).toBeNull();
    expect(h.requests[1]?.url.searchParams.get("cursor")).toBe("c1");
    expect(h.envelopes).toHaveLength(1);
    h.connection.stop();
  });
});

describe("IN-34 reconnect", () => {
  it("IN-34: backoff is exponential with full jitter from 1 s to 60 s", () => {
    expect(reconnectDelay(1, 0.5)).toBe(500);
    expect(reconnectDelay(2, 0.5)).toBe(1000);
    expect(reconnectDelay(7, 0.999)).toBeLessThan(60_000);
    expect(reconnectDelay(20, 0.5)).toBe(30_000);
    expect(reconnectDelay(3, 0)).toBe(0);
  });

  it("IN-34: a dropped stream waits a jittered delay and resumes after the last envelope", async () => {
    const h = harness({
      transports: ["sse"],
      responses: [sseResponse(`id: c1\nevent: x\ndata: ${JSON.stringify(envelope("c1"))}\n\n`)],
    });
    h.connection.start();
    await settle();
    expect(h.statuses.at(-1)).toMatchObject({ state: "waiting", attempt: 1, delayMs: 500 });
    h.timers.at(-1)?.callback();
    await settle();
    expect(h.requests[1]?.headers.get("last-event-id")).toBe("c1");
    h.connection.stop();
  });

  it("IN-52: an overloaded node's close 1013 waits for its retry-after", async () => {
    const h = harness({});
    h.connection.start();
    await settle();
    const socket = h.sockets[0];
    socket?.open();
    socket?.drop(1013, "retry-after=3");
    await settle();
    expect(h.statuses.at(-1)).toMatchObject({
      state: "waiting",
      delayMs: 3000,
      transport: "websocket",
    });
    h.connection.stop();
  });

  it("IN-33: a policy close for a suspended subscriber stops for good", async () => {
    const h = harness({});
    h.connection.start();
    await settle();
    const socket = h.sockets[0];
    socket?.open();
    socket?.drop(1008, "auth_subscriber_suspended");
    await settle();
    expect(h.errors[0]?.reason).toBe("auth_subscriber_suspended");
    expect(h.statuses.at(-1)).toMatchObject({ state: "closed" });
    expect(h.sockets).toHaveLength(1);
  });

  it("IN-52: SSE answered 503 waits for Retry-After", async () => {
    const h = harness({
      transports: ["sse"],
      responses: [new Response("", { status: 503, headers: { "retry-after": "2" } })],
    });
    h.connection.start();
    await settle();
    expect(h.statuses.at(-1)).toMatchObject({ state: "waiting", delayMs: 2000 });
    h.connection.stop();
  });
});

describe("IN-23 SSE parsing", () => {
  it("IN-23: events, multi-line data, comments, ids and CRLF line ends are parsed", async () => {
    const events = [];
    for await (const event of readSse(
      sseResponse(": hi\r\nevent: a\r\ndata: one\r\ndata: two\r\nid: 5\r\n\r\ndata: three\n\n")
        .body as ReadableStream<Uint8Array>,
    )) {
      events.push(event);
    }
    expect(events).toEqual([
      { event: "a", data: "one\ntwo", id: "5" },
      { event: "message", data: "three", id: "5" },
    ]);
  });
});
