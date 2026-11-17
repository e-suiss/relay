import { describe, expect, it } from "vitest";
import { RelayAgent, type MailboxRecord } from "../src/agent.js";
import { VersionedDeduper, openThenList } from "../src/core/stream-sync.js";
import { RelayServerClient } from "../src/server.js";
import { noSleep } from "./helpers.js";

type Handler = (url: URL, init: RequestInit | undefined) => unknown;

function server(handler: Handler): RelayServerClient {
  return new RelayServerClient({
    baseUrl: "https://relay.example.com",
    authenticate: () => ({ authorization: "DPoP token" }),
    sleep: noSleep,
    fetch: async (input, init) =>
      new Response(JSON.stringify(handler(new URL(input), init)), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
  });
}

function record(id: string, seq: number): MailboxRecord {
  return { object: "mailbox_record", id, seq } as unknown as MailboxRecord;
}

describe("IN-27 IN-28 open the stream, then list, then deduplicate", () => {
  it("IN-27: an event not newer than what was seen is dropped", () => {
    const deduper = new VersionedDeduper<{ id: string; v: number }>(
      (item) => item.id,
      (item) => item.v,
    );
    expect(deduper.accept({ id: "a", v: 2 })).toBe(true);
    expect(deduper.accept({ id: "a", v: 2 })).toBe(false);
    expect(deduper.accept({ id: "a", v: 1 })).toBe(false);
    expect(deduper.accept({ id: "a", v: 3 })).toBe(true);
    expect(deduper.known("a")).toBe(3);
  });

  it("IN-28: the stream opens before the history is listed and its buffer is applied after it", async () => {
    const steps: string[] = [];
    const seen: string[] = [];
    let push = null as ((item: { id: string; v: number }) => void) | null;
    const subscription = await openThenList<{ id: string; v: number }>({
      open: (emit) => {
        steps.push("open");
        push = emit;
        return () => steps.push("close");
      },
      history: () => {
        steps.push("history");
        push?.({ id: "a", v: 1 });
        push?.({ id: "b", v: 3 });
        return [
          { id: "a", v: 2 },
          { id: "b", v: 2 },
        ];
      },
      key: (item) => item.id,
      version: (item) => item.v,
      onItem: (item) => seen.push(`${item.id}${item.v}`),
    });
    expect(steps).toEqual(["open", "history"]);
    expect(seen).toEqual(["a2", "b2", "b3"]);
    push?.({ id: "a", v: 3 });
    push?.({ id: "a", v: 3 });
    expect(seen).toEqual(["a2", "b2", "b3", "a3"]);
    subscription.close();
    expect(steps).toEqual(["open", "history", "close"]);
  });
});

describe("X-30 agent helpers", () => {
  it("X-30: awaitWaitpoint polls until the waitpoint leaves open and stalled, and a hint wakes it", async () => {
    const states = ["open", "stalled", "resolved"];
    let reads = 0;
    const agent = new RelayAgent(
      server((url) => {
        expect(url.pathname).toBe("/v1/waitpoints/wp_1");
        const state = states[Math.min(reads, states.length - 1)];
        reads++;
        return { object: "waitpoint", id: "wp_1", state };
      }),
    );
    const waiting = agent.awaitWaitpoint("wp_1", { minIntervalMs: 60_000, maxIntervalMs: 60_000 });
    for (let index = 0; index < 50 && reads < 3; index++) {
      await new Promise((resolve) => setTimeout(resolve, 1));
      agent.wake();
    }
    const waitpoint = await waiting;
    expect((waitpoint as { state: string }).state).toBe("resolved");
    expect(reads).toBe(3);
  });

  it("X-30: lease and ack go to the mailbox endpoints with the lease id and record ids", async () => {
    const calls: { path: string; body: unknown; key: string | null }[] = [];
    const agent = new RelayAgent(
      server((url, init) => {
        calls.push({
          path: url.pathname,
          body: typeof init?.body === "string" ? JSON.parse(init.body) : null,
          key: new Headers(init?.headers).get("idempotency-key"),
        });
        if (url.pathname === "/v1/mailbox/leases") {
          return { object: "mailbox_lease", lease_id: "mbl_1", lease_expires_at: null, records: [record("mbr_1", 1)] };
        }
        return { object: "mailbox_ack", results: [{ record_id: "mbr_1", result: "acked" }], acked_cursor: "1:1" };
      }),
    );
    const lease = (await agent.leaseMailbox({ max: 5 })) as unknown as { lease_id: string };
    await agent.ackMailbox(lease.lease_id, ["mbr_1"]);
    expect(calls.map((call) => call.path)).toEqual(["/v1/mailbox/leases", "/v1/mailbox/acks"]);
    expect(calls[0]?.body).toEqual({ max: 5 });
    expect(calls[1]?.body).toEqual({ lease_id: "mbl_1", record_ids: ["mbr_1"] });
    expect(calls.every((call) => call.key !== null)).toBe(true);
  });

  it("AG-21: followMailbox reads after every hint and delivers each record once", async () => {
    const pages: Record<string, { records: MailboxRecord[]; cursor: string }> = {
      start: { records: [record("mbr_1", 1), record("mbr_2", 2)], cursor: "c2" },
      c2: { records: [record("mbr_3", 3)], cursor: "c3" },
      c3: { records: [], cursor: "c3" },
    };
    const agent = new RelayAgent(
      server((url) => {
        const since = url.searchParams.get("since") ?? "start";
        const page = pages[since] ?? { records: [], cursor: since };
        return { object: "mailbox_records", ...page, has_more: false, resync_required: false };
      }),
    );
    const delivered: string[] = [];
    let hint = null as ((record?: MailboxRecord) => void) | null;
    const subscription = await agent.followMailbox({
      open: (push) => {
        hint = push;
        push(record("mbr_2", 2));
        return () => undefined;
      },
      onRecord: (item) => delivered.push((item as unknown as { id: string }).id),
    });
    for (let index = 0; index < 20 && delivered.length < 3; index++) {
      await new Promise((resolve) => setTimeout(resolve, 1));
    }
    expect(delivered).toEqual(["mbr_1", "mbr_2", "mbr_3"]);
    hint?.();
    await new Promise((resolve) => setTimeout(resolve, 5));
    expect(delivered).toEqual(["mbr_1", "mbr_2", "mbr_3"]);
    subscription.close();
  });
});
